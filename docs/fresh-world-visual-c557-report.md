# Fresh 2048 visual QA — c5571e5

Scope: actual Main/menu/server wire at client `c5571e5`, production WASM built
from backend `914dec5` (SHA-256
`3eff7f52805f4df3f1ef8963c54083aeed39d4ecb5f8954e139766859efbb1c8`).
This is scoped evidence, not release approval; rerun after the combined fixes.

**Latest completed evidence:**
`/tmp/opencode/continuum-world/evidence/fresh-visual-c557-run9/` — 45 actual
captures plus `contact-sheet.png`, state sidecars, phase trace, logs, and manifest.
It includes the additional 1280px cut -1/15 captures. All owned processes were
reaped, listener released, and private data/credentials deleted. The two P2
findings and distant-hatch diagnostic below reproduce. Latest Fit observation:
**100/256 overview rows after 92.0 seconds, 39,936 samples still pending**.
These are incomplete Fit captures at a bounded deadline, not a performance pass.

## Verified

Evidence: `/tmp/opencode/continuum-world/evidence/fresh-visual-c557-run5/`.

- Actual menu → Servers → typed private endpoint → Join server works. No
  production/client state overrides or regenerated private bindings.
- Fresh bootstrap is 2048×2048, 4096/4096 chunks. Main naturally centers on
  `(1024,1024)`. Starter origin is `(1012,1012)`; eight initial colonists are at
  x=1022–1025, y=1019–1020.
- Real publisher reset while connected, seed 1234: Preparing world → Generating
  terrain → Building overview → Validating world → Founding colony → Loading
  nearby terrain → Ready. Trace contains 141 non-Ready generation observations;
  none became playable or had a pending mutation. The early mouse-input attempt
  occurred with the loading overlay active; it created no building.
- Main reached Ready with real nearby terrain, not just server Ready. The reset
  trace distinguishes server progress from the separate nearby-terrain phase.
- Actual worker/hauler simulation supplied 25 stored wood. Publisher paused
  before UI construction. A normal Operator requested one 2×2 room at
  `(1012,1012,0)`, costing 20 wood; server returned clearance 4 and thermal
  resistance `2.0`. Free Storage was independently overlaid through Zones.
- `08-room-request-pending-1280.png` shows real **Pending** and **Request pending ·
  wait for server response**, followed by the settled room/storage inspection.
- `10-room-storage-inspection-1280.png` and
  `11-room-storage-inspection-1920.png`: separate Construction and Zones panels,
  correct R2/cost/storage information, tan room perimeter, cyan selected cell.
  Both panels stay inside the viewport, without horizontal overflow. The shorter
  720px layout uses vertical panel scrolling.

## Capture notes

Primary UI scale is 100%. Camera scale is independent: initial 16px/cell (100%),
mid 8px/cell (50%), close room interaction 32px/cell (200%). Resizing retains
the application's own relative camera zoom behavior.

The `generation-*.png` files in run5 predate the driver's generation-ID filename
improvement: `generation-ready-4.png` is the **pre-reset generation-1 baseline**.
Consult JSON sidecars; the reset pipeline and final Ready are generation 2.

Run1–4 did not complete the capture scenario because of driver bring-up errors. Run1 encountered
an offline nil-db observation bug; run2 an early static-class/autoload compile
dependency; run3 attempted input before the reset arrived; run4 accidentally
clicked the real loading Disconnect button. Each runtime was reaped and private
data deleted. Run1's initial port-bind check lacked SO_REUSEADDR and reported a
false cleanup failure; an immediate independent check found connection refused
and successfully rebound port 50061. The corrected checker passes later runs.

Run5's optional 150% navigation attempt failed in the capture driver's popup
input routing. Its successful primary screenshots and authoritative room state
remain valid; this is not an application scale-layout finding.

An incidental production diagnostic occurred after run4's real loading-screen
Disconnect: `client.log` reports an unsubscribe send on a closed WebSocket and,
later, `_on_bootstrap_timeout: Cannot convert argument 1 from Object to Object`.
This may overlap the assigned bootstrap lifecycle work. Recheck normal loading
Disconnect at the combined SHA; no production change was attempted here.

## New ecology presentation finding

**P2 — loaded authoritative ecology is presented as unavailable outside the
starter's operational Tile rows.** In run7, navigate normally to `(512,512)`,
16px/cell, cut z=15. Wait until the captured renderer has zero pending samples,
then hover the center. `14c-remote-detail-loaded-1920.json` records the real
loaded column values: fertility 100, forest density 128, moisture 159 (u8).
`14d-remote-ecology-tooltip-1920.png` nevertheless says “terrain data unavailable”
for Farming, Logging, and Hunting. This is not an unloaded-terrain case.

The data path explains the discrepancy: `colony_map.gd::_ecology_fields` only
reads tile-linked operational ecology, while `terrain_model.gd::frame_samples`
has the new compact column ecology. `render_frame` then drops those ecology
fields before presenting the art frame. The loaded remote landscape shows
textured soil/stone and meaningful height contours but no corresponding
forest-cover/soil-ecology cue. This deserves a client/model/art follow-up; no
production code was changed in this QA worktree.

By contrast, `14b-navigation-real-pending-1920.png` captures genuine unloaded
detail immediately after a camera jump: diagonal hatching and “Terrain loading ·
waiting for viewport data.” It subsequently resolves into the fully loaded
`14c` image. Reducer **Pending** (room request), terrain **loading**, and the
misleading loaded-ecology **unavailable** state are separately evidenced.

At the default cut z=0, the surroundings are dominated by exposed grey stone
and the flat starter soil square. Raising the real cut toolbar to z=15 reveals
the generated height contours. Thus the initial view alone does not convey the
full landscape variation; the cut must be stated when reviewing terrain images.

## Other normal-path observations

- **P2 — deferred panel focus callback can retain a freed Control.** Runs 6 and 7
  both log `workspace_deck.gd::_reveal_retained_body_focus: Cannot convert argument
  1 from Object to Object` during the actual panel/selection/resize sequence.
  `workspace_deck.gd:532–540` binds the Control across several frames. A freed
  argument fails before the handler's validity check and before
  `_body_focus_reveal_pending` is cleared, potentially preventing subsequent
  keyboard-focus auto-reveal. No screenshot clipping was attributed to this
  error in these captures. Route to the panel owner for a focused reproduction.
- **Known performance work remains necessary.** In run7, the normal camera jump
  from `(512,512)` at 16px/cell to `(960,960)` at 8px/cell, 1920×1080, cut z=15,
  did not finish its bounded 60-second settling wait. Last observation: 28
  resident sources, 32 detail entries, 30,492 render samples, 3,751 pending
  samples; Main still Ready and no loading error. This is software-rendered
  llvmpipe evidence, not a hardware performance estimate. It overlaps the
  assigned coalescing/streaming work; no duplicate fix was attempted.

## Completed bounded capture run8

`/tmp/opencode/continuum-world/evidence/fresh-visual-c557-run8/` completed the
primary sequence, including near/mid, cut -1/0/15, remote detail, and Fit at both
1280×720 and 1920×1080. Import-time hash verification confirmed **195 production
script/binding/shader files unchanged** in the disposable client.

Fit remained incomplete after a 91.4-second observation window: **97/256 overview
rows received, 40,704 pending samples**, no loading error. See
`16-fit-pending-1920.png`, `17-fit-bounded-outcome-1920.png`, and
`18-fit-1280.png`. The hatched region is explicitly still loading. This is a
bounded observation failure, not a successful full-world or performance capture.
The mid-distance view did eventually finish between its deadline and screenshot;
its `*-deadline.json` correctly records zero pending samples at image time,
while `result.json` preserves the earlier incomplete last observation.

**P3 rendering diagnostic:** Fit also logged eight `Invalid polygon data,
triangulation failed` errors from `MapPaint.hatch` (`map_paint.gd:91`), called by
`ColonyMap._draw_excavations` (`colony_map.gd:1425`). This is the actual starter
excavation at distant zoom, not a fixture. Route the tiny-scale hatch path to the
art/map owner; no production change was made here.

150% UI scale remains unverified: the optional native-popup navigation sequence
failed in the driver. No scale-layout defect is inferred from that failure.

All run8 process groups were reaped, its listener released, and private
home/database/publisher credentials removed. Images, sidecars, redacted logs,
and the result manifest remain in the evidence directory. Combined-SHA rerun and
independent approval are still required.

Cleanup fault checks also passed against an actual owned runtime: an intentional
publisher-command failure, and then an injected `OSError` while archiving
`server.log`. Both reaped the runtime, released its listener, and removed private
credentials/data. Manifests are in sibling directories
`fresh-visual-cleanup-fault/` and `fresh-visual-archive-fault/`.
