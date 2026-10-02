# Glyphs

Status glyphs for the UI theme; see [the UI redesign](../../../../../docs/ui-redesign.md).

Status glyphs on a 16px grid, with their colours baked in (an `<img>` cannot inherit colour). The shapes carry the meaning; colour only reinforces it.

- `critical.svg`: diamond in `critical` with an `on-critical` mark. Act now.
- `warn.svg`: triangle in `warn` with an `on-warn` mark. Drifting out of band.
- `notice.svg`: ring in `ink-muted`. Worth knowing; also the "Nominal" empty state.
- `ack.svg`: ringed check in `ink-muted`. An alert someone has acknowledged.
- `auto.svg`: loop arrow in `accent`. An automation acted.
- `player.svg`: cursor in `accent`. A player acted.

For Godot, import at 16px and 2× scale for 200% UI; for modulated use, recolour the single-ink glyphs (`notice`, `ack`, `auto`, `player`) to white and set `modulate` from the token.
