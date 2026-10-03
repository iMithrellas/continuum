# Construction and Zones integration

## UI contract

- `construction` / **Construction** is a new independently openable panel (F11).
- `operations` / **Zones** retains the previous panel identity and F4 shortcut.
  Its work-order and enable/disable controls still act on authoritative Tile rows.
- F1–F10, other saved panel geometry, flags, ordering and workspace titles survive.
  Old layouts receive Construction closed; new planning presets open both panels.
- Main owns `_planning_system`; the map continues emitting the generic rectangle
  request. The room/zone callback provides honest hover and drag descriptions.
- In compact layouts, activating either drawing tool or excavation collapses its
  panel so the map is reachable. Header status and Escape/right-click cancellation
  remain available. Zone choices reflow from two to four columns.
- Selection presents room identity, insulation, paid cost and clearance separately
  from operational usage. Demolition has no refund and does not clear usage.
  Clearing a selected usage cell leaves the room. Legacy multicell usage clears
  by its durable Tile identity as a whole, explicitly stated in the tooltip.
- Room overlay lives in `ui/components/room_overlay.gd`: subtle floor tint, open
  corners, envelope edge and roof cue. It does not alter terrain/entity painting.

## Locked backend boundary

Main calls these new placement reducers through capability-checked generated
methods (building bindings supplied by backend dependency `9cb1d93`):

```
construct_room(x0, y0, x1, y1, z, clearance_height)
demolish_building(building_id)
designate_zone_at(x0, y0, x1, y1, z, TileKind)
clear_zone(tile_id)
```

Bounds are inclusive, normalized by the map, and limited to 4,096 cells. Room
cost is 5 wood/cell, minimum clearance four layers; usage is free with four-layer
clearance. Existing conflicting usage requires clearing. Room and usage creation
are locally allowed in either order; server acceptance remains authoritative.

`building` and `building_thermal_property` queries are appended when matching
generated table properties exist. Building fields follow the locked contract;
thermal display reads the generated field `thermal_resistance_m_2_k_per_w`.
The generator canonicalizes the schema's `m2` segment to `m_2`. No generated
bindings were hand-edited. Connected server acceptance remains an integration gate.
Missing reducers produce visible “Bindings unavailable” feedback rather than an
optimistic local success. Planning tests and render captures use actual generated
`ContinuumBuilding` and `ContinuumBuildingThermalProperty` rows through their
generated tables/indexes. The serialization regression disables `map_intent_override`
and exercises Main → generated reducers → SDK BSATN serialization with a recorder
only at the transport boundary. It checks exact signed XYZ/bounds, the Storage enum
tag, u16 clearance, u64 building identity and u32 Tile identity, plus denied roles.

The later 2048×2048 centered-world requirement does not change this API. Planning
uses authoritative bounds and coordinates; the 24/128/256 test fixtures remain
intentional. The map-client integration must preserve its generation-ready gate
when combining `_planning_allowed()` / `_state_ready` with bootstrap/streamed
subscriptions. These panels do not implement world generation or streaming.

Temperature, navigation blocking, walls and food spoilage are not claimed as
implemented. The room is explicitly described as a traversable property envelope.

## Verification

Run from the repository root:

```
godot --headless --path client/godot res://tools/planning_test.tscn
godot --headless --path client/godot res://tools/map_client_test.tscn
godot --headless --path client/godot res://tools/workspace_test.tscn
godot --headless --path client/godot res://tools/session_handoff_test.tscn
godot --headless --path client/godot res://tools/production_wiring_test.tscn
godot --headless --path client/godot res://tools/main_menu_test.tscn
```

Planning checks cover real buttons, reversed drag/release routing through Main,
Operator dispatch, Viewer/Unknown denial, detached DB and detached Main denial,
pending duplicate prevention, failure/timeout feedback, role-revoked late replies,
independent demolition/usage clear, overlap descriptions, cost/usage conflicts,
4,096-cell bounds, keyboard cancellation and lossless workspace migration.

Private X11 / real OpenGL capture (Xvfb on PATH):

```
python client/godot/tools/map_client_x11.py res://tools/planning_capture.tscn -- \
  --screen=1280x720 --scale=150 --panel=operations \
  --capture=/tmp/opencode/panels-zones.png
```

Capture uses actual Main with typed 256×256 terrain, usage, room and thermal rows.
It checks window containment, horizontal fit, focusability and
compact auto-collapse. Matrix: 1280×720 and 1920×1080 at 100% / 150%; both compact
panels separately, plus `--panel-width=280` for minimum-width verification.

`--header-state=cancelled`, `escape` or `menu` also verifies real native-window
permission cancellation / Escape / Panels-dropdown routing. Idle outcome messages
remain in planning panels without adding a header row. The original narrow idle
header budget remains 202px; an armed tool adds exactly its measured row and gutter.
The UI geometry gate checks containment, telemetry baselines, distinct eight-pixel
gutters, Cancel reachability, seventy-percent map/panel area in the narrow tall
fixture, and exact return to the original budget after Escape.
