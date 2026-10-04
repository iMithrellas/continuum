# Atlas command card and floating panels

**Authority:** the user-provided D1 `Hybrid-Live.dc.html` prototype and its
README supersede the older two-strip composition described in `ui-redesign.md`.
This is a production-Godot interaction and visual target, not an instruction to
port the prototype markup or its fictional sample colony data. The current live
renderer, backend/data semantics, and no-docking/map-space invariants remain in
force. A diagnostic/command-card screenshot is not the entire production UI.

## Composition and visual targets

- The live map renderer fills the workspace viewport. The navigator and panels
  float over it; opening or moving them never reserves map width. Do not replace
  the live map with the prototype's static art.
- At the 1440×900 reference artboard, the left Command card is inset 8 logical
  pixels, 272 pixels wide, and spans the available height with 8-pixel bottom
  inset. It has a 32-pixel search field, scrollable grouped contents, and a
  fixed bottom utility area. Preserve usable bounds at smaller viewports; the
  reference's 560-pixel minimum artboard height is not a minimum window size.
- Keep the D1 dark charcoal surface/border hierarchy, restrained shadows,
  subdued secondary text, IBM Plex-like sans/mono hierarchy, and teal focus /
  active accent. Match the supplied HTML's values where applicable, using the
  project's theme/components rather than copying HTML or hard-coding sample
  state.
- The three micro-panels (Colony status, Session/connection, Performance) are
  compact overlay tabs when collapsed and compact readouts when expanded; the
  reference tab height is 30 logical pixels. They are separate from the Command
  card and do not create global header strips.

## Navigator contents and interactions

The card's panel list has 13 operator panels in these groups (keep this order):

| Group | Panels |
| --- | --- |
| Colony | Colony overview, Colonist roster, Colony policies, Colony status |
| Build | Construction, Zones, Tile inspector |
| Supply | Resources |
| Signals | Alerts, Activity feed, Session trends |
| System | Session / connection, Performance |

The Command card supports searchable panel navigation; workspace selection and
management; per-panel open, collapsed-tab, and closed states; layout Save/Revert;
and utility routes for return digest, settings, servers, and disconnect. Search
opens with **Ctrl+K**; the prototype also specifies left-edge dwell reveal after
**120 ms** and autoclose after **280 ms**. Support keyboard focus and reduced
motion without making reveal/autoclose the only way to reach controls.

Workspace hotkeys are **Alt+1…4** for the four built-in workspaces and Alt+1…9
for available custom workspaces. Panel hotkeys are **R** Resources, **P** Colony
policies, **B** Construction, **I** Tile inspector, and **F8** Performance.
Preserve legacy **F9** administration and **F10** local diagnostics/developer
utilities; their existing permission/role checks remain authoritative. Never
make a shortcut bypass permissions. Resolve key conflicts and text-entry focus
before dispatching shortcuts.

Every panel has exactly the semantic visibility states **open**, **collapsed**
(tab only), and **closed**. Pinning locks panel geometry; it does not dock the
panel or reserve map space. Drag and resize affordances remain discoverable.
“Save” records the current layout as the local preference baseline; “Revert”
restores that baseline. Normal preference persistence/autosave remains local,
not a server mutation. Workspace preference version **4** must migrate versions
1, 2, and 3 while retaining access and useful geometry; discard obsolete dock
state rather than reintroducing docking.

## Data, diagnostics, and evidence

Render only actual client/server data. Resource rates and trends must say
warming, unavailable, or estimated when appropriate; do not turn missing rates
into zero or fabricate histories, colony actors, alert attribution, or trend
lines. Show identity only when authenticated identity is available, with an
explicit **Identity:** prefix; do not substitute prototype names such as
`mithrel` or invented operator/colonist names. Preserve F9/F10 permissions and
the existing diagnostic workflows. The mockup's numeric examples and alert
stories are visual placeholders, not fixture truth or backend requirements.

Keep two evidence paths distinct:

1. **Demo fixture:** deterministic sample content may be used only in an
   explicitly labelled demo/mock fixture for visual exploration. It must not
   imply live state, be mistaken for an acceptance screenshot, or leak into
   production UI.
2. **Real UI fixture:** screenshot/integration acceptance instantiates actual
   `scenes/main.tscn` and the live map renderer, supplying generated typed local
   rows without connecting to a backend. Use real or honestly unavailable
   values, and assert actual composition/interaction. This is backend-free, not
   a static mock.

Tests should cover screenshot/layout at the reference dimensions and constrained
sizes; filtering and keyboard navigation; workspace actions; all three panel
states; pin geometry lock, drag/resize, Save/Revert and v1/v2/v3-to-v4 migration;
map viewport and picking invariance; honest missing/warming data; identity
labeling; and F9/F10 permission behavior. Test fixtures must not dispatch live
reducers or mutate persistent server state.

## Developer checks

`client/godot/gdformatrc` sets gdformat's 100-character line length and excludes
addons and generated SpacetimeDB bindings. `client/godot/gdlintrc` is the lint
configuration (present in the integration worktree); do not broaden the new
recipes to addons/bindings or unrelated legacy files. The scoped `lint-gd` and
`fmt-gd-check` recipes in the justfile list only Atlas-owned/currently targeted
scripts and `tools/atlas_ui*.gd`. `test-atlas-ui` invokes the backend-free
`client/godot/tools/atlas_ui_checks.py` runner with `GODOT` support. That runner
is being added separately; this recipe does not claim it already exists or
passes. A render mode should be added only when that runner defines its CLI and
private-display behavior.

The older `docs/ui-redesign.md` remains useful for shared simulation, map,
honest-data, floating-only, and permission invariants. Its two-strip header
layout is superseded by this document and is no longer an acceptance target.
