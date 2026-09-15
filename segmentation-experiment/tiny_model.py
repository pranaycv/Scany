"""Tiny document segmenters for on-device Core ML (iPhone 12 / iOS 15)."""

from __future__ import annotations

import platform

import torch
import torch.nn as nn

ARCH_CNN = "cnn"
ARCH_TRANSFORMER = "transformer"
ARCH_CHOICES = (ARCH_CNN, ARCH_TRANSFORMER)


class ConvBNReLU(nn.Module):
    def __init__(self, cin: int, cout: int, stride: int = 1) -> None:
        super().__init__()
        self.block = nn.Sequential(
            nn.Conv2d(cin, cout, 3, stride=stride, padding=1, bias=False),
            nn.BatchNorm2d(cout),
            nn.ReLU(inplace=True),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.block(x)


class TinyDocumentNet(nn.Module):
    """256×256 RGB → page mask, presence score, and normalized TL-TR-BR-BL quad.

    Depthwise-light UNet (~0.4M params) so it stays real-time on Neural Engine.
    """

    def __init__(self, base: int = 16) -> None:
        super().__init__()
        c1, c2, c3, c4 = base, base * 2, base * 3, base * 4
        self.stem = ConvBNReLU(3, c1)
        self.down1 = ConvBNReLU(c1, c2, stride=2)
        self.enc2 = ConvBNReLU(c2, c2)
        self.down2 = ConvBNReLU(c2, c3, stride=2)
        self.enc3 = ConvBNReLU(c3, c3)
        self.down3 = ConvBNReLU(c3, c4, stride=2)
        self.enc4 = ConvBNReLU(c4, c4)
        self.down4 = ConvBNReLU(c4, c4, stride=2)
        self.bottleneck = ConvBNReLU(c4, c4)

        self.up4 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec4 = ConvBNReLU(c4 + c4, c4)
        self.up3 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec3 = ConvBNReLU(c4 + c3, c3)
        self.up2 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec2 = ConvBNReLU(c3 + c2, c2)
        self.up1 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec1 = ConvBNReLU(c2 + c1, c1)

        self.mask_head = nn.Conv2d(c1, 1, kernel_size=1)
        self.pool = nn.AvgPool2d(16)
        self.presence_head = nn.Linear(c4, 1)
        self.quad_head = nn.Linear(c4, 8)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        s1 = self.stem(x)
        e2 = self.enc2(self.down1(s1))
        e3 = self.enc3(self.down2(e2))
        e4 = self.enc4(self.down3(e3))
        b = self.bottleneck(self.down4(e4))

        d4 = self.dec4(torch.cat([self.up4(b), e4], dim=1))
        d3 = self.dec3(torch.cat([self.up3(d4), e3], dim=1))
        d2 = self.dec2(torch.cat([self.up2(d3), e2], dim=1))
        d1 = self.dec1(torch.cat([self.up1(d2), s1], dim=1))

        mask_logits = self.mask_head(d1)
        pooled = self.pool(b).flatten(1)
        presence_logits = self.presence_head(pooled)
        quad = torch.sigmoid(self.quad_head(pooled))
        return mask_logits, presence_logits, quad


class TinyAttention(nn.Module):
    """Scaled dot-product attention using matmul only (Core ML cannot convert nn.MultiheadAttention)."""

    def __init__(self, dim: int, heads: int) -> None:
        super().__init__()
        if dim % heads != 0:
            raise ValueError(f"dim {dim} must divide heads {heads}")
        self.heads = heads
        self.head_dim = dim // heads
        self.scale = self.head_dim ** -0.5
        self.qkv = nn.Linear(dim, dim * 3)
        self.proj = nn.Linear(dim, dim)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        b, n, c = x.shape
        qkv = self.qkv(x).reshape(b, n, 3, self.heads, self.head_dim)
        qkv = qkv.permute(2, 0, 3, 1, 4)
        q, k, v = qkv[0], qkv[1], qkv[2]
        attn = torch.matmul(q, k.transpose(-2, -1)) * self.scale
        attn = torch.softmax(attn, dim=-1)
        out = torch.matmul(attn, v)
        out = out.transpose(1, 2).reshape(b, n, c)
        return self.proj(out)


class TinyTransformerBlock(nn.Module):
    def __init__(self, dim: int, heads: int, mlp_ratio: float = 4.0) -> None:
        super().__init__()
        hidden = int(dim * mlp_ratio)
        self.norm1 = nn.LayerNorm(dim)
        self.attn = TinyAttention(dim, heads)
        self.norm2 = nn.LayerNorm(dim)
        self.mlp = nn.Sequential(
            nn.Linear(dim, hidden),
            nn.GELU(),
            nn.Linear(hidden, dim),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = x + self.attn(self.norm1(x))
        x = x + self.mlp(self.norm2(x))
        return x


class TinyDocumentTransformer(nn.Module):
    """SAM-style tiny student: conv patch stem, ViT encoder, CNN mask decoder.

    256×256 RGB → page mask, presence, and normalized TL-TR-BR-BL quad.
    Global self-attention runs on a 16×16 token grid (~0.5M params).
    """

    def __init__(
        self,
        dim: int = 64,
        depth: int = 6,
        heads: int = 4,
        mlp_ratio: float = 4.0,
        image_size: int = 256,
    ) -> None:
        super().__init__()
        grid = image_size // 16
        self.grid = grid
        self.dim = dim

        self.stem = ConvBNReLU(3, 16)
        self.down1 = ConvBNReLU(16, 24, stride=2)
        self.enc2 = ConvBNReLU(24, 24)
        self.down2 = ConvBNReLU(24, 32, stride=2)
        self.enc3 = ConvBNReLU(32, 32)
        self.down3 = ConvBNReLU(32, 48, stride=2)
        self.enc4 = ConvBNReLU(48, 48)
        self.patch = ConvBNReLU(48, dim, stride=2)

        self.pos = nn.Parameter(torch.zeros(1, grid * grid, dim))
        self.blocks = nn.ModuleList(
            [TinyTransformerBlock(dim, heads, mlp_ratio) for _ in range(depth)]
        )
        self.norm = nn.LayerNorm(dim)

        self.up4 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec4 = ConvBNReLU(dim + 48, 48)
        self.up3 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec3 = ConvBNReLU(48 + 32, 32)
        self.up2 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec2 = ConvBNReLU(32 + 24, 24)
        self.up1 = nn.Upsample(scale_factor=2, mode="nearest")
        self.dec1 = ConvBNReLU(24 + 16, 16)

        self.mask_head = nn.Conv2d(16, 1, kernel_size=1)
        self.presence_head = nn.Linear(dim, 1)
        self.quad_head = nn.Linear(dim, 8)
        self._init_transformer()

    def _init_transformer(self) -> None:
        nn.init.trunc_normal_(self.pos, std=0.02)
        for module in self.modules():
            if isinstance(module, nn.Linear):
                nn.init.trunc_normal_(module.weight, std=0.02)
                if module.bias is not None:
                    nn.init.zeros_(module.bias)
            elif isinstance(module, nn.LayerNorm):
                nn.init.ones_(module.weight)
                nn.init.zeros_(module.bias)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        s1 = self.stem(x)
        e2 = self.enc2(self.down1(s1))
        e3 = self.enc3(self.down2(e2))
        e4 = self.enc4(self.down3(e3))
        patches = self.patch(e4)
        b, c, h, w = patches.shape
        tokens = patches.flatten(2).transpose(1, 2) + self.pos
        for block in self.blocks:
            tokens = block(tokens)
        tokens = self.norm(tokens)
        encoded = tokens.transpose(1, 2).reshape(b, c, h, w)

        d4 = self.dec4(torch.cat([self.up4(encoded), e4], dim=1))
        d3 = self.dec3(torch.cat([self.up3(d4), e3], dim=1))
        d2 = self.dec2(torch.cat([self.up2(d3), e2], dim=1))
        d1 = self.dec1(torch.cat([self.up1(d2), s1], dim=1))

        mask_logits = self.mask_head(d1)
        pooled = tokens.mean(dim=1)
        presence_logits = self.presence_head(pooled)
        quad = torch.sigmoid(self.quad_head(pooled))
        return mask_logits, presence_logits, quad


class ExportNet(nn.Module):
    """Core ML graph: RGB 0–1 tensor in, sigmoid mask + presence out."""

    def __init__(self, net: nn.Module) -> None:
        super().__init__()
        self.net = net

    def forward(self, image: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        mask_logits, presence_logits, _ = self.net(image)
        return torch.sigmoid(mask_logits), torch.sigmoid(presence_logits)


def normalize_arch(arch: str) -> str:
    name = (arch or ARCH_CNN).strip().lower().replace("-", "_")
    aliases = {
        "cnn": ARCH_CNN,
        "unet": ARCH_CNN,
        "tiny": ARCH_CNN,
        "tiny_document_net": ARCH_CNN,
        "transformer": ARCH_TRANSFORMER,
        "vit": ARCH_TRANSFORMER,
        "tiny_transformer": ARCH_TRANSFORMER,
        "tiny_document_transformer": ARCH_TRANSFORMER,
    }
    if name not in aliases:
        raise ValueError(f"Unknown arch {arch!r}; expected one of {ARCH_CHOICES}")
    return aliases[name]


def build_model(arch: str = ARCH_CNN, **kwargs) -> nn.Module:
    name = normalize_arch(arch)
    if name == ARCH_TRANSFORMER:
        return TinyDocumentTransformer(**kwargs)
    return TinyDocumentNet(**kwargs)


def arch_from_checkpoint(ckpt: dict | None, fallback: str = ARCH_CNN) -> str:
    if isinstance(ckpt, dict) and ckpt.get("arch"):
        return normalize_arch(str(ckpt["arch"]))
    return normalize_arch(fallback)


def pick_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if platform.machine() == "x86_64":
        return torch.device("cpu")
    if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def count_params(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())
