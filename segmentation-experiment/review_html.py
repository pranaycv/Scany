"""Write a static HTML gallery for reviewing teacher-model quads."""

from __future__ import annotations

import json
from pathlib import Path


def write_review_index(review_dir: Path, records: list[dict]) -> Path:
    review_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = review_dir / "manifest.json"
    manifest_path.write_text(json.dumps(records, indent=2), encoding="utf-8")

    cards = []
    for rec in records:
        pred = rec.get("pred") or {}
        found = bool(pred.get("found"))
        status = "found" if found else "miss"
        if rec.get("is_negative_gt") and found:
            status = "false-positive"
        elif rec.get("is_negative_gt") and not found:
            status = "true-negative"
        iou = pred.get("iou_vs_gt")
        iou_html = f"{iou:.3f}" if isinstance(iou, (int, float)) else "—"
        score = pred.get("score")
        score_html = f"{score:.3f}" if isinstance(score, (int, float)) else "—"
        overlay = rec.get("overlay_path", "")
        mask = rec.get("mask_path", "")
        cards.append(
            f"""
            <article class="card" data-status="{status}" data-iou="{iou if isinstance(iou, (int, float)) else ''}">
              <a href="{overlay}" target="_blank"><img src="{overlay}" alt="{rec.get('filename', '')}"></a>
              <div class="meta">
                <strong>{rec.get('filename', '')}</strong>
                <div>split={rec.get('split')} · idx={rec.get('index')} · {status}</div>
                <div>score={score_html} · IoU vs GT={iou_html} · model={pred.get('model', '—')}</div>
                <div>prompt={pred.get('prompt', '—')}</div>
                <div class="quad">quad={json.dumps(pred.get('quad_norm'))}</div>
                {f'<a href="{mask}" target="_blank">mask</a>' if mask else ''}
              </div>
            </article>
            """
        )

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Scany segmentation experiment — review</title>
  <style>
    :root {{ color-scheme: dark; }}
    body {{ font: 14px/1.4 ui-sans-serif, system-ui; margin: 0; background: #111; color: #eee; }}
    header {{ position: sticky; top: 0; background: #111e; padding: 16px 20px; border-bottom: 1px solid #333; backdrop-filter: blur(8px); }}
    h1 {{ margin: 0 0 8px; font-size: 18px; }}
    .tools {{ display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }}
    input, select {{ background: #222; color: #eee; border: 1px solid #444; padding: 6px 8px; border-radius: 6px; }}
    .legend span {{ margin-right: 12px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 14px; padding: 16px; }}
    .card {{ background: #1a1a1a; border: 1px solid #333; border-radius: 10px; overflow: hidden; }}
    .card img {{ width: 100%; height: 220px; object-fit: contain; background: #000; display: block; }}
    .meta {{ padding: 10px 12px; }}
    .quad {{ font-family: ui-monospace, monospace; font-size: 11px; word-break: break-all; opacity: 0.85; }}
    .card[data-status="miss"] {{ border-color: #a33; }}
    .card[data-status="false-positive"] {{ border-color: #a60; }}
    .card[data-status="true-negative"] {{ border-color: #385; }}
    .hidden {{ display: none; }}
  </style>
</head>
<body>
  <header>
    <h1>Teacher annotations — convex document quads</h1>
    <div class="legend">
      Overlay: <span style="color:#7CFF8E">green = dataset GT</span>,
      <span style="color:#5CC8FF">cyan = teacher quad</span>,
      magenta wash = teacher mask
    </div>
    <div class="tools">
      <label>Filter
        <select id="status">
          <option value="all">all</option>
          <option value="found">found</option>
          <option value="miss">miss</option>
          <option value="true-negative">true negative</option>
          <option value="false-positive">false positive</option>
        </select>
      </label>
      <label>Search <input id="q" placeholder="filename"></label>
      <span id="count"></span>
    </div>
  </header>
  <section class="grid" id="grid">
    {''.join(cards)}
  </section>
  <script>
    const cards = [...document.querySelectorAll('.card')];
    const status = document.getElementById('status');
    const q = document.getElementById('q');
    const count = document.getElementById('count');
    function apply() {{
      const s = status.value;
      const needle = q.value.toLowerCase();
      let n = 0;
      for (const card of cards) {{
        const okStatus = s === 'all' || card.dataset.status === s;
        const okText = card.innerText.toLowerCase().includes(needle);
        const show = okStatus && okText;
        card.classList.toggle('hidden', !show);
        if (show) n += 1;
      }}
      count.textContent = n + ' shown / ' + cards.length + ' total';
    }}
    status.addEventListener('change', apply);
    q.addEventListener('input', apply);
    apply();
  </script>
</body>
</html>
"""
    index_path = review_dir / "index.html"
    index_path.write_text(html, encoding="utf-8")
    return index_path
