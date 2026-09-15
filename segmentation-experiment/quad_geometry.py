"""Convert a binary mask into an ordered convex quadrilateral."""

from __future__ import annotations

import numpy as np

try:
    import cv2
except ImportError as exc:  # pragma: no cover
    raise SystemExit("opencv-python-headless is required") from exc


CORNER_NAMES = ("tl", "tr", "br", "bl")


def order_tl_tr_br_bl(points: np.ndarray) -> np.ndarray:
    """Order 4 points as top-left, top-right, bottom-right, bottom-left in image space."""
    pts = np.asarray(points, dtype=np.float32).reshape(4, 2)
    by_y = pts[np.argsort(pts[:, 1])]
    top = by_y[:2][np.argsort(by_y[:2, 0])]
    bottom = by_y[2:][np.argsort(by_y[2:, 0])]
    return np.stack([top[0], top[1], bottom[1], bottom[0]], axis=0)


def is_convex_quad(points: np.ndarray) -> bool:
    pts = np.asarray(points, dtype=np.float64).reshape(4, 2)
    sign = 0.0
    for i in range(4):
        a = pts[i]
        b = pts[(i + 1) % 4]
        c = pts[(i + 2) % 4]
        cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0])
        if abs(cross) < 1e-8:
            continue
        if sign == 0.0:
            sign = cross
        elif sign * cross < 0:
            return False
    return True


def quad_to_dict(points: np.ndarray) -> dict[str, list[float]]:
    ordered = order_tl_tr_br_bl(points)
    return {name: [float(x), float(y)] for name, (x, y) in zip(CORNER_NAMES, ordered)}


def dict_to_quad(data: dict) -> np.ndarray | None:
    try:
        return np.array([data[name] for name in CORNER_NAMES], dtype=np.float32)
    except (KeyError, TypeError):
        return None


def normalize_quad(points: np.ndarray, width: int, height: int) -> dict[str, list[float]]:
    scale = np.array([max(width, 1), max(height, 1)], dtype=np.float32)
    ordered = order_tl_tr_br_bl(points) / scale
    ordered = np.clip(ordered, 0.0, 1.0)
    return {name: [float(x), float(y)] for name, (x, y) in zip(CORNER_NAMES, ordered)}


def denormalize_quad(norm: dict, width: int, height: int) -> np.ndarray:
    pts = dict_to_quad(norm)
    if pts is None:
        raise ValueError("quad dict is missing tl/tr/br/bl")
    return pts * np.array([width, height], dtype=np.float32)


def quad_iou(quad_a: np.ndarray, quad_b: np.ndarray, width: int, height: int) -> float:
    """IoU of two convex quads, computed on a compact raster."""
    max_side = 256
    scale = min(max_side / max(width, 1), max_side / max(height, 1), 1.0)
    w = max(int(round(width * scale)), 1)
    h = max(int(round(height * scale)), 1)
    a = order_tl_tr_br_bl(quad_a) * scale
    b = order_tl_tr_br_bl(quad_b) * scale
    mask_a = np.zeros((h, w), dtype=np.uint8)
    mask_b = np.zeros((h, w), dtype=np.uint8)
    cv2.fillConvexPoly(mask_a, np.round(a).astype(np.int32), 1)
    cv2.fillConvexPoly(mask_b, np.round(b).astype(np.int32), 1)
    inter = int(np.logical_and(mask_a, mask_b).sum())
    union = int(np.logical_or(mask_a, mask_b).sum())
    return float(inter) / float(union) if union else 0.0


def mask_to_convex_quad(mask: np.ndarray) -> np.ndarray | None:
    """Largest-component contour → convex hull → 4 corners."""
    if mask is None:
        return None
    binary = (np.asarray(mask) > 0).astype(np.uint8)
    if binary.ndim == 3:
        binary = binary[..., 0]
    if int(binary.sum()) < 64:
        return None

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea)
    if cv2.contourArea(contour) < 64:
        return None

    hull = cv2.convexHull(contour)
    peri = cv2.arcLength(hull, True)
    if peri < 1:
        return None

    quad = None
    for eps in np.linspace(0.008, 0.06, 20):
        approx = cv2.approxPolyDP(hull, float(eps) * peri, True)
        if len(approx) == 4:
            quad = approx.reshape(4, 2).astype(np.float32)
            break

    if quad is None:
        # Fall back to the min-area rectangle, then snap those corners onto the hull.
        rect = cv2.minAreaRect(hull)
        box = cv2.boxPoints(rect).astype(np.float32)
        hull_pts = hull.reshape(-1, 2).astype(np.float32)
        snapped = []
        for corner in box:
            d = np.linalg.norm(hull_pts - corner[None, :], axis=1)
            snapped.append(hull_pts[int(np.argmin(d))])
        quad = np.stack(snapped, axis=0)

    ordered = order_tl_tr_br_bl(quad)
    if not is_convex_quad(ordered):
        ordered = order_tl_tr_br_bl(cv2.boxPoints(cv2.minAreaRect(hull)))
    return ordered


def gt_corners_from_sample(sample: dict) -> np.ndarray | None:
    if sample.get("is_negative"):
        return None
    keys = [
        "corner_tl_x",
        "corner_tl_y",
        "corner_tr_x",
        "corner_tr_y",
        "corner_br_x",
        "corner_br_y",
        "corner_bl_x",
        "corner_bl_y",
    ]
    values = [sample.get(key) for key in keys]
    if any(v is None for v in values):
        return None
    return np.array(values, dtype=np.float32).reshape(4, 2)


def cheap_document_box(image_rgb: np.ndarray) -> list[float] | None:
    """Coarse axis-aligned box used as a SAM 2 prompt when SAM 3 is unavailable."""
    h, w = image_rgb.shape[:2]
    gray = cv2.cvtColor(image_rgb, cv2.COLOR_RGB2GRAY)
    blur = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blur, 40, 120)
    edges = cv2.dilate(edges, np.ones((5, 5), np.uint8), iterations=1)
    contours, _ = cv2.findContours(edges, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    best = None
    best_area = 0.0
    img_area = float(w * h)
    for contour in contours:
        area = float(cv2.contourArea(contour))
        if area < img_area * 0.05 or area > img_area * 0.98:
            continue
        peri = cv2.arcLength(contour, True)
        approx = cv2.approxPolyDP(contour, 0.02 * peri, True)
        if len(approx) < 4:
            continue
        x, y, bw, bh = cv2.boundingRect(approx)
        if area > best_area:
            best_area = area
            pad = 8
            best = [
                float(max(x - pad, 0)),
                float(max(y - pad, 0)),
                float(min(x + bw + pad, w - 1)),
                float(min(y + bh + pad, h - 1)),
            ]
    return best
