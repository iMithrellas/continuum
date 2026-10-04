# UI redesign

> **Superseded composition:** the user-provided D1 Atlas command-card prototype
> replaces the two-global-strip header requirements below. The current visual
> and interaction acceptance targets are in [Atlas command card and floating
> panels](atlas-ui.md). Shared no-docking/map-space, live-renderer, honest-data,
> and permission invariants remain applicable; do not treat the old two-strip
> composition as current acceptance criteria.

**Status:** integrated candidate; combined independent review required before main fast-forward
**Design source:** supplied UI design package; `tokens.json` is authoritative over prose and HTML previews.
**Implementation base:** `a39e9bcd72d953c178e6c4c9dce0bb2ac67359e3`  
**Theme:** `res://ui/theme` — colors, fonts, spacing, glyphs and icon styling

**Reusable controls:** `res://ui/components`

`ThemeTokens` provides theme values. Reusable controls include `AlertRow`,
`ColonistCard` and `ResourceReadout`. Session observations, return snapshots and
map presentation live in purpose-named scripts alongside the existing client.

## Goal and constraints

Apply the UI redesign to the existing Godot client while preserving current simulation, persistence and world-rendering behavior. The design package defines visual language and UI data needs; its example simulations do **not** authorize new simulation rules, tables, endpoints, or server-side feature work.

- Keep work split into isolated worktrees and conventional commits. Integrate candidate commits by cherry-pick in dependency order; resolve integration conflicts in the integration worktree, not by rewriting worker history.
- Ownership is disjoint: foundation, components, workspace/settings, map, then main/data/diagnostics integration. A worker changing shared API must coordinate before expanding scope.
- Do not alter unrelated work. This plan and implementation start from the clean specified base. Existing F9/F10/admin/developer diagnostics and inline diagnostic host must survive all UI gating.
- Never make presentation data look more authoritative than it is. Missing, warming, stale, estimated and unavailable values need distinct honest treatments; do not fabricate zeroes, actors, trends, alert state, or history.
- Record divergences from the package as explicit implementation assumptions or unresolved follow-ups; do not silently expand backend scope.

### User override: floating panels only

The user's explicit interaction requirement supersedes the package's illustrative
docking reference: **remove docking entirely**. The map fills the workspace area;
panels are overlays and must never reserve map width or artificially shrink its
viewport. Every panel has discoverable titlebar dragging and resize affordances.
Pinning locks geometry only; it is not docking. No Dock/Float controls, dock hosts,
or persisted dock keys remain in the final candidate. Existing v1/v2 workspace
preferences must migrate to floating geometry without losing panel access.

This override is implemented in the integrated candidate. Compact mode applies
below 640 logical pixels wide or 400 logical pixels high, retaining the full map
under the active panel and explicit Map access. It does not impose a fixed
100%/125% two-dock or 150% compact policy. v1/v2 preferences migrate to v3 while
retaining remembered geometry and preferences; docking keys are removed.

### User override: two quiet global strips

The global chrome is a nominal 40-logical-pixel status strip and a 32-logical-pixel
workspace strip, without horizontal scrollbar stripes. Status shows time, plain
resource name/value pairs, observed rates when space permits, compact connection
health and Menu. Real resource warnings retain glyph, severity word and estimated
game-hour horizon. Missing/warming rates stay honest in each resource tooltip and
a shared status when space permits; no unavailable measurement becomes zero.
Crew/role and secondary rates collapse into tooltips at narrow widths; Menu keeps
the actual full authenticated identity available and offers copying it.

The workspace strip contains tabs (active workspace at constrained widths) and
one Panels menu. That menu exposes only permitted panels, their shown/pinned
state, workspace selection, new/rename, save/reset/delete, header visibility and
Map view. “Since you left” moves into Menu; the existing launch-menu route still
provides settings, servers, disconnect and exit. Default selection instructions
move off the global chrome; editing intent retains visible map-local copy and
Cancel access. Zoom/layer navigation is a content-width top-left map overlay
below floating panels, with explicit map-input exclusion. Action failures are
visible floating critical feedback, not a permanent third strip.

Status layout measures the combined live resource/control minima and reserves
Menu plus neutral connection health first. Secondary rates, crew and role yield
before warnings. When the remaining width cannot fit every stock/forecast, an
internal resource grid reflows below the metadata row **inside the same status
group**; all four glyph/word/estimated game-hour forecasts stay visible, even at
240 logical pixels. The workspace strip stays below that group; the map fills
the remaining workspace area. Calm data restores the nominal height without
resizing the window. Large quantities may use a `~` approximation with the full
stored value in the tooltip; positive ETA below 0.1 game hour reads `<0.1 game h`,
not an apparent zero. These are presentation changes, not estimator/threshold
changes. Unchanged resource inputs retain their controls and Menu focus.

## Ownership, phases and dependencies

| Phase / owner | Scope | Depends on / handoff |
| --- | --- | --- |
| 1. Foundation worker | `res://ui/theme` token/theme API, type styles, glyphs and fonts/license; provide token-based logical font/theme foundations only. | First. Publish API and theme variant names for component, workspace, map and integration workers. UI-scale and reduced-motion preferences belong to phase 3. |
| 2. Component worker | Reusable visual components and data presentation: panels, buttons, tabs primitives as appropriate, resource/need/colonist/alert/log/digest/automation rows. | Foundation API. Consume existing client data only; communicate fields that are unavailable rather than inventing them. |
| 3. Workspace/settings worker | Workspace/tab and floating-panel orchestration, preferences for UI scale and reduced motion, access to existing panels and settings. | Foundation API; coordinate component ownership of shared tab/panel widgets. Preserve diagnostic entry points and host. |
| 4. Map specialist | Adapt existing map renderer to UI redesign map presentation and overlays. Do not replace renderer or world model. | Foundation colors/glyphs and existing map picking/rendering contracts. Preserve world semantics listed below. |
| 5. Main/data/diagnostics integration worker | Wire views to current client/server data, app entry/return flow, connection/diagnostics, responsive composition and end-to-end QA. | Phases 1–4 APIs and commits. No schema/API change without separate permission, migration and world-scope contract. |
| 6. Independent reviewer | Review integrated result against checklist, inspect regressions and run tests/QA; report confidence and fatal findings. | Candidate integration commit. Require confidence ≥0.92 and zero fatal findings before main fast-forward. |

Dependencies are interface dependencies, not permission for one owner to take another's files. Each worker commits only owned files and provides commit ID, test evidence and known gaps. Integration should be a linear candidate suitable for fast-forward to main after review.

## Token, font and theme implementation

- Copy package assets under `res://ui/theme`; treat `tokens.json` as source of truth. Include the accompanying OFL license with the IBM Plex WOFF2 assets. Preserve required copyright/license notices and do not rename/modify the font family.
- Implement the agreed token API: `ThemeTokens.color`, `.number`, `.font`, `.font_size`, `.line_height`, `.glyph`, `.apply_label`; support the complete agreed theme-variant map. Resolve aliases safely, validate missing/cyclic aliases and malformed values, and report resource-load/save failures rather than producing a partial theme silently.
- Godot 4 supports WOFF2, but verify imports and exported/runtime loads in this project. Preserve all seven supplied IBM Plex faces/weights and sensible glyph fallback for user/player text.
- Reproduce package colors, spacing, sizes, radii, shadows and type. Keep status, accent and map-color meanings separate. HTML/CSS literal values are visual references, not an alternative token authority.
- UI scale has one authority: `Window.content_scale_factor`, with 100%, 125%, 150% options. Migrate old font sizes 10–24 to the nearest allowed scale without shrinking text below 11 logical px; default 13 logical px. Avoid multiplying both font sizes and content scale. Respect existing user settings where migration is possible.
- Add a reduced-motion preference and honor it for the critical-alert pulse. Nominal UI remains still. Do not suppress meaningful world movement/sprite walk animation as if it were chrome motion.
- Theme variation coverage must include all agreed controls/states used by the UI, including normal/hover/pressed/disabled/focus buttons, primary and critical buttons, panels, labels, tabs, meter bands and relevant status tags. Missing states should be explicit, not engine-default accidents.

## Data semantics and explicit non-goals

### Existing data only

Render what current APIs actually provide. Existing custom automation remains absent; storage remains unlimited. Do not add storage capacity, overflow rules, automation rules, thresholds on the server, new event tables, or new endpoints as part of this UI adoption.

Current alerts have shared acknowledgement as a boolean only: there is no actor, handle or acknowledgement timestamp contract. Current events are freeform messages capped at 200, with no structured source. Use existing literal message/timestamp where available; never parse text to claim a known actor or event type. Actor/time attribution, structured event source, automation, permissions, migration and world-scope contracts are follow-up backend work requiring a separate decision. The 200-event cap is a history-coverage limitation, not evidence that unlimited event retention is required.

Optional future-model fields may be rendered only when genuinely supplied. Do not change schema in order to make a sample preview look complete. Surface unsupported features as unavailable/omitted, not simulated.

### Presentation calculations

- Needs are presentation-only satisfaction values clamped to 0–100: `Fed = 100 - hunger`, `Rest = 100 - fatigue`, `Leisure = 100 - recreation`, `Mood = actual mood`, `Output = actual productivity`. Do not feed these derived meters back into simulation or create server alerts from their thresholds.
- Meter thresholds are client presentation thresholds: warn 35, critical 15, using **strictly below** comparisons. Highest severity wins. Show threshold ticks and trend only when supported. Do not show fake zero or a flat trend when input/history is unavailable.
- Resource rates are per in-game hour. Candidate local observed rates/trends must be labelled as observed since connection and shown as warming until adequate samples exist; distinguish estimated from authoritative values. Negative-rate ETA is an estimate with a horizon. Under 24 in-game hours is warn; under 2 in-game hours is critical; highest severity wins. Always show the horizon with an estimate. Thresholds are UI presentation only.
- At `time_scale=6` game seconds per real second, one in-game day takes four real hours; use the actual subscribed `time_scale` rather than a fixed assumption. Example times/horizons use explicit in-game units; do not present example timestamps as live state.
- Only alert levels/state actually present in data may be shown. Do not turn a need meter threshold into an invented server alert. Current acknowledgement can stop a pulse globally via the existing shared boolean, but must not show an acknowledging player or time that the backend does not provide.

### Map preservation contract

Adapt the existing renderer, not a new TileMap architecture. Preserve physical cells at 0.5m, world coordinates, cut-height/depth occlusion, whole-entity blur, idle cache budgets, durable facility IDs and existing picking. Preserve meaningful world movement and sprite walk animation.

- 32px internal raster is acceptable when displayed at 100% as 16 logical px. Zoom/render changes must not alter simulation coordinates or selection.
- Use `map-ground` / `map-ground-deep` as neutral presentation materials and retain tooltips with actual IDs. Do not apply zone colors to ordinary terrain.
- Group visual regions by same kind and base z using four-neighbour occupied physical cells. Give stable type/count labels; do not invent authored zone names. Excavation designations are labelled excavation, never a planned/built mine. Draw pins only where alert location is known.
- Preserve paper casing, zone patterns/plates where applicable, selection and z-level cues without changing map domain meaning. The map fills the workspace area beneath floating overlays; opening, moving, resizing or pinning panels must not reserve or shrink its viewport. Compact panels only as required by viewport bounds and floating-panel minimums.

## Component scope and acceptance criteria

All ten documented components are in scope. Build reusable UI from real client state and skip unavailable states instead of hard-coding preview data.

| Component | Acceptance |
| --- | --- |
| **Panel** | Sentence-case visible title, optional live count, body; floating/collapsed/pinned states only. Use `shadow-float`, canonical-token headers/rims, discoverable titlebar drag and resize affordances. Pin locks geometry only. Body padding/flush rows and minimum width rules are respected where layout permits. No Dock/Float UI or map reservation. |
| **Button** | Verb-first labels; default/primary/quiet/critical/disabled styles and 24/28px sizes; disabled reason in label where applicable; one primary per view; keyboard/gamepad focus ring. Critical action is outlined, not solid red. |
| **Tabs** | Workspace selection, accent underline, fixed/new separator, highest available warn/critical count/glyph when data exists; tab label itself does not take status color. No fabricated counts. |
| **ResourceReadout** | Name/value/rate with units and in-game-hour horizon; nominal grey; threshold glyph and color apply together; connection and player/role only from available data. Estimated local rates are explicitly provisional. |
| **NeedMeter** | Defined satisfaction mapping/clamp, ticks at 35/15, strict-below severity, glyph/word and correct trend treatment; unavailable trend is not zero/flat. No server-side alert or simulation effects. |
| **ColonistCard** | Compact row and expanded card from existing fields; worst out-of-band need only in roster, neutral state tags except real problem state, automation shown only if present; selection is synchronized with existing map selection. |
| **AlertRow** | Existing level/title/detail/time and shared acknowledgement boolean; order by level then consequence only where consequence data exists; critical unacknowledged pulse stops globally and obeys reduced motion. Do not invent acknowledgement actor/time. Empty state uses nominal notice treatment, not a green tick. |
| **LogEntry** | Render literal event message/time from existing capped event feed; preserve chronology; do not parse message for actor/source, fabricate glyph semantics or claim reliable repeat grouping when data is unstructured. Structured grouping waits for backend contract. |
| **AwayDigest** | Return experience may summarize only known data: elapsed interval/resources/events if available. Fixed section order and empty-section treatment only when data supports it; no fake “handled” counts or attribution. Clearly acknowledge limited 200-event coverage rather than imply complete history. |
| **ZoneTile** | Existing renderer with preserved physical/world contracts; ground/depth and selection/known pins remain accurate; grouped regions use deterministic four-neighbour grouping and type/count, excavation stays excavation, no invented zones/names. Respect zoom, cache and map-space budgets. |

## Test and review plan

Run relevant project tests and Godot headless/editor import checks after asset/theme integration. Verify token alias error handling, all theme resource paths, WOFF2 import, packaged license, and runtime use of the agreed token API. Add focused tests for need conversion/clamping and strict thresholds, rate/ETA severity boundaries, missing/warming rate/trend states, region grouping/base-z boundaries, stable selection/picking, and acknowledgement boolean behavior. Tests must not mutate persistent server state.

Manual QA at **1440×900** and **960×640**, at **100%, 125%, 150%** scale:

- nominal and problem states; no fabricated zero, trend, actor, history or automation;
- keyboard and gamepad focus, primary/disabled/critical controls, and reduced-motion preference;
- no clipping or illegible text; floating panels remain reachable and compact to actual viewport constraints;
- titlebar drag, resize affordances and pin geometry lock work; v1/v2 preferences migrate without persisted dock keys, and panels never change map viewport geometry or picking;
- map coordinate/picking and z-depth behavior unchanged; world movement remains; only the unacknowledged critical alert chrome pulses;
- connection-loss/diagnostic workflows, F9/F10, admin/developer access, and inline diagnostics remain available;
- no server mutation during QA, and no unexpected backend/schema changes in candidate diff.

Independent review reports checklist results, regression findings and confidence. Do not fast-forward unless confidence is at least 0.92 and there are no fatal findings; document and resolve fatal issues first.

## Known gaps / follow-up decisions

### Implemented integration and offline verification

The production main scene now uses resource readouts, compact roster rows and a
selected expanded card, needs, shared-boolean alerts, literal activity entries,
and a modal local-return digest. Roster selection reaches map selection and Go to
uses the current replicated coordinates. Current alerts have no positions, so
alert pins remain empty. Existing hauling/meal/recreation policies remain actual
controls; no fictional automation or rest reducer is exposed.

Scale is owned only by `Window.content_scale_factor`; the legacy fixed viewport
stretch has been removed. Old font preferences migrate to 100/125/150%, while
logical type stays at least 11px. Floating frames use the foundation's two-layer
shadow. The floating-only user override above is integrated; earlier dock
behavior is no longer an acceptance target. Licensed
Lucide geometry with literal square caps is embedded in
`UiIcons`, including runtime token-colored frame/toolbar icons.

Observed rates use a constant-size connection origin and minute-throttled,
bounded game-clock samples. They warm up for a usable game hour; need trends use
an actual last-hour anchor. Paused clocks display rate unavailable. ETA copy is
rounded for display only; thresholds use the original measurements.

Return snapshots are local last-session observations keyed by endpoint,
database, profile and authenticated identity. Only minimal resources, generation,
game clock and event watermark persist, never credentials, roles or tokens.
Generation/backward-clock/watermark changes invalidate baselines. Same-generation
database replacement cannot always be detected. The digest explicitly caveats
the 200-event cap and unavailable player attribution/handled summaries; it is not
permanent history. Resource comparisons explicitly retain their reconnect capture
boundary, while “Needs you now” follows live alert acknowledgement, activity and
severity. Open comparisons are invalidated immediately on observed reset; modal
focus and scroll survive meaningful updates. Reducer failures remain visible in
a dismissible action banner independent of neutral Live connection health.

```sh
just test-ui
# Private Xvfb + DummyAudio Godot wrapper, not the human desktop:
GODOT=/path/to/godot-private PATH=/path/to/private-xvfb/bin:$PATH \
  just test-ui-render
```

`UI_CHECK_OUTPUT` and `UI_RENDER_OUTPUT` select evidence directories under
`/tmp/opencode`. The first recipe isolates HOME/XDG/runtime state, runs merged
backend-free contracts and typed production-main composition, then exports a real
PCK and runs its widgets from an empty directory. The render recipe captures 48
actual-main scale/state/focus/reduced-motion cases plus four floating-frame and
two return-modal cases (54 total), and checks roster GUI input,
280px panel floors, selected critical contrast, modal
blocking, changing-value control-focus retention and focus restoration. The
telemetry body stays at the logical topbar height; inline diagnostics remain in
the status strip and do not create another global row or scrollbar stripe.
These are not the earlier chrome-only fixture.
The production-main fixture replaces the earlier dock-reservation checks with
full-workspace map geometry, direct overlay ownership and absence of Dock/Float
controls. Actual native-window input at current global UI scale exercises titlebar
drag, corner resize, hidden-header strip drag and pin lock, then validates map
global picking and workspace-popup focus/input isolation. Workspace tests cover
v1/v2 migration, all resize handles, overlap/z-order and permission cancellation.
The focused floating matrix runs eight actual-main cases at 1440×900 and 960×640,
100% and 150%, nominal and problem states; the review matrix additionally checks
the action-failure/digest callbacks at 125%. Private captures disable vsync only
for the test process and retain timeout diagnostics. Historical dock-based passes
are not approval of the new interaction contract.

```sh
UI_CHECK_OUTPUT=/tmp/opencode/continuum-ui-integration-state/floating-combined-gates \
  just test-ui
GODOT=/path/to/godot-private PATH=/path/to/private-xvfb/bin:$PATH \
  UI_RENDER_OUTPUT=/tmp/opencode/continuum-ui-integration-state/floating-combined-gpu \
  python3 client/godot/tools/ui_render_matrix.py --live --floating-only
# Target the two combined-review fatal regressions, including an actual PCK:
python3 client/godot/tools/ui_check.py --review-only
# Two-strip header, scaled native input and menu reachability; includes 4K:
GODOT=/path/to/godot-private PATH=/path/to/private-xvfb/bin:$PATH \
  python3 client/godot/tools/ui_render_matrix.py --live --header-only
# Aggregate multi-warning budgets, including 240 logical pixels:
GODOT=/path/to/godot-private PATH=/path/to/private-xvfb/bin:$PATH \
  python3 client/godot/tools/ui_render_matrix.py --live --budget-only
```
Fixtures never connect to a server or dispatch a live reducer. Combined review
must still inspect the candidate and actual PNGs; successful fixture tests are
not independent approval.

1. Alert acknowledgement actor/time needs a server contract, permissions and world scope before attribution can be displayed.
2. Durable away-digest history and structured event source/actor/verb/subject/count need a separately scoped migration/API decision; current freeform 200-row feed is not a reliable event schema.
3. Automation UI remains empty/absent until actual automation data exists; no sample rule should imply support.
4. Resource storage is unlimited in current behavior; no capacity or overflow alert is implied by the design mock.
5. Minute-throttled observed-rate history is bounded to 122 samples; a usable game-hour anchor is required. Rates are connection means, not server production accounting. Confidence intervals and durable telemetry remain future work.
6. Existing spec leaves details such as trend bucket boundaries and alert consequence tie-breaking unspecified. Use deterministic presentation-only behavior only where input exists and record the choice; no backend rules.

## Commit and handoff

Conventional commits, lowercase imperative subject, for example `docs: plan the ui redesign`. Workers report commit ID, owned paths, tests and known gaps. Integrator records the ordered candidate commits and final verification evidence; independent reviewer supplies confidence and fatal/nonfatal findings before main fast-forward.
