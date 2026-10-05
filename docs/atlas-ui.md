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
configuration; do not broaden the new recipes to addons/bindings or unrelated
legacy files. `lint-gd` and `fmt-gd-check` first `cd client/godot` so both tools
discover their project config. Their scoped list covers the Atlas workspace,
window, command, diagnostics, menu, chart, UI data, icons, shared
readout/feed/roster components, the `tools/atlas*.gd` family, and retained map,
planning, role, workspace, menu, and diagnostics tests. `test-atlas-ui` runs the
backend-free `client/godot/tools/atlas_ui_checks.py` runner with `GODOT`
support. It imports the project, tests the actual Main composition against a
generated typed local database including a 64×64 world, and makes reducer calls
fail locally before SDK transport; it does not connect to a live server. The
fixture is production UI with deterministic demonstration rows, not live colony
state.

Run contracts with `just test-atlas-ui`. A render run requires private Xvfb;
provide its executable without hard-coding a machine-specific path in the repo:

```sh
XVFB=/path/to/Xvfb python3 client/godot/tools/atlas_ui_checks.py --render
```

The standard render matrix captures diagnostics with Command open, daily, and
settings scenarios. For a narrow, single screenshot (paths are written under
the runner's reported `/tmp/opencode` evidence directory), run:

```sh
XVFB=/path/to/Xvfb python3 client/godot/tools/atlas_ui_checks.py \
  --render --screen=360x480 --scale=150 --workspace=diagnostics --command
```

To capture fixtures only, without running contracts, add `--fixture-only`. The
single-capture options include `--workspace=diagnostics`, `--command`, and
`--settings`. `--keep-open` requires `--render --screen=...`; it leaves the
fixture interactive on the runner's private Xvfb display until closed. This is
not the human desktop and must not be treated as a live-server session. All
home/XDG state is isolated.

Persisted UI scale options are exactly **100%, 125%, 150%, and 175%**; retain and
restore each choice as a user preference. Reference CSS dimensions are at 100%
logical scale; the prototype's `uiScale` value of 125% is presentational state
and does not actually scale its HTML. Godot applies real scale through the
window content scale, so apparent pixel geometry differences at 125% and other
non-100% settings are intentional. Private screenshots use software llvmpipe:
rendered Performance/FPS values are not hardware performance measurements or
representative live-server telemetry. Screenshot/test execution is evidence
only; it does not by itself certify acceptance before final review.

The older `docs/ui-redesign.md` remains useful for shared simulation, map,
honest-data, floating-only, and permission invariants. Its two-strip header
layout is superseded by this document and is no longer an acceptance target.
