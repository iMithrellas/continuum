"""Normalize vendored interface wrappers only; never modify status glyphs."""
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "ui/theme/icons"
for source in sorted(root.glob("*.svg")):
    text = source.read_text()
    assert 'stroke-width="2.25"' in text and 'viewBox="0 0 24 24"' in text
    source.write_text(text.replace('stroke-linecap="butt"', 'stroke-linecap="square"'))
