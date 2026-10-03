"""Package already-rendered private GL evidence; never synthesize game pixels."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "client/godot/build/world-art"
DEST = ROOT / "docs/evidence"
DEST.mkdir(parents=True, exist_ok=True)


def sheet(name, panels, columns, width):
    tile_width = width // columns
    tile_height = round(tile_width * 9 / 16)
    rows = (len(panels) + columns - 1) // columns
    image = Image.new("RGB", (width, rows * (tile_height + 26)), "#162324")
    draw = ImageDraw.Draw(image)
    for index, (label, path) in enumerate(panels):
        x, y = index % columns * tile_width, index // columns * (tile_height + 26)
        original = Image.open(SOURCE / path).convert("RGB")
        image.paste(original.resize((tile_width, tile_height), Image.Resampling.LANCZOS), (x, y + 26))
        draw.text((x + 10, y + 8), label, fill="#e2dbc0")
    image.save(DEST / name)


for resolution, width in [("1280x720", 1920), ("1920x1080", 2880)]:
    panels = []
    for phase in ["before", "after"]:
        for zoom, cell in [("near", 40), ("mid", 16), ("far", 4)]:
            panels.append((f"{phase.upper()} / 128 world / {resolution} / {zoom} / {cell}px cell", f"{phase}/128-{resolution}-{zoom}.png"))
    sheet(f"world-art-128-{resolution}.png", panels, 3, width)
    panels = [(f"2048 logical / {resolution} / {zoom} / resident authoritative patch", f"after/2048-{resolution}-{zoom}.png") for zoom in ["near", "mid", "far", "overview"]]
    sheet(f"world-art-2048-{resolution}.png", panels, 2, 1920)

logs = []
for name in ["before-128", "after-128", "before-256", "after-256", "after-2048"]:
    logs.append(f"--- {name} ---\n" + (SOURCE / f"{name}.log").read_text())
(DEST / "world-art-metrics.txt").write_text("Private Xvfb OpenGL / Mesa llvmpipe. Shared-host wall-clock observations, not hardware GPU claims.\n\n" + "\n".join(logs))
print("Evidence sheets and original measurement logs:", DEST)
