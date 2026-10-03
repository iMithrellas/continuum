# Fresh-world visual capture

`scripts/internal/capture-fresh-world.py` drives the actual Main scene and menu
against a new, private SpacetimeDB 2.10 production database. It uses the checked-in
typed bindings unchanged. The isolated Godot driver sends mouse/key input to real
controls; only map camera positioning uses the existing camera API.

```sh
PATH=/tmp/opencode/ux-panels-evidence/usr/bin:$PATH \
python scripts/internal/capture-fresh-world.py \
  --wasm /absolute/path/to/production/continuum_module.wasm \
  --evidence /tmp/opencode/continuum-world/evidence/fresh-visual-UNIQUE
```

The runtime, database name, port, Xvfb display, publisher credentials, client home,
and settings are private. Do not supply a test-probe WASM. The runner grants the
normal client Operator through the publisher reducer and obtains construction
wood through actual workers. Only the publisher changes simulation speed.

## Capture provenance

Initial generation normally finishes before Main joins. To observe progress
reliably, the runner joins that Ready world, then the private publisher invokes
`reset_world_large(2048, 2048, 1234)` while Main remains connected. The
`generation-2-*.png` images show that real reset's generation pipeline, **not an
initial-join loading phase**. Generation 1's Ready capture is the pre-reset
baseline. The driver does not create terrain, cache entries,
generation rows, resource fixtures, local permissions, or substitute dispatch.

Each PNG has a JSON state sidecar. `progress.ndjson` records server-derived phase
and work counters together with actual Main readiness, overlay, and pending
status. A filename containing `pending` describes the requested observation;
the sidecar is authoritative about whether the request remained pending at the
rendered frame. A fast acknowledgement may settle before a screenshot.

Camera cell size is separate from UI scale: the initial camera is 16 pixels per
cell, close inspection uses 32, and mid views use 8. All primary captures use
100% UI scale; the secondary 150% capture is labeled explicitly.

Fit has a bounded observation deadline. Capturing its current appearance is not
a performance acceptance result. Software-rendered llvmpipe timings must not be
presented as hardware performance.

Exit 0 / `complete: true` means the primary capture sequence finished. Inspect
loading observations, Fit counters, logs, and `secondary_scale_error`; it is not
a correctness or release gate, and optional 150% capture may remain unverified.

## Cleanup and evidence

All owned process groups are terminated and reaped before fallible evidence
copying. Private data and credentials are removed in a nested `finally`, even
if evidence archiving fails. `result.json` records cleanup and port-rebind
verification. Logs redact JWTs and identity strings; private homes and publisher
stores are never archived.

The report is scoped visual QA. A rerun at the combined integration SHA and
independent review are required for release approval.
