# Production world bindings

Bindings are generated from the actual **production** module on a private
SpacetimeDB **2.10.0** runtime. Never enable `generation-test-probes` for this
artifact. Do not publish to, reset, or borrow the shared port3001 server.

Build explicitly into the disk-backed worker cache (not the worktree tmpfs):

```sh
CARGO_TARGET_DIR=/home/mithrel/.cache/opencode-continuum-build-cache/world-bindings \
  cargo build --manifest-path backend/spacetimedb/Cargo.toml \
  --release --target wasm32-unknown-unknown
```

Start an exclusively owned runtime with a random loopback port, private data/JWT
paths, private `HOME`, and a private CLI `--root-dir`; publish the explicit
`world-bindings/wasm32-unknown-unknown/release/continuum_module.wasm` artifact.
Terminate/wait for that runtime in `finally`, including failures. Keep tokens,
JWT keys, runtime logs and server data outside git and do not print tokens.

## Clean regeneration

Only prune this known-obsolete generated allowlist, inside your own worktree:

```sh
python - <<'PY'
from pathlib import Path
schema = Path('client/godot/spacetime_bindings/schema')
for relative in ('types/continuum_own_role.gd', 'types/continuum_own_role.gd.uid'):
    (schema / relative).unlink(missing_ok=True)
PY
godot --headless --path client/godot --editor --import
godot --headless --path client/godot --script res://tools/generate_bindings.gd -- \
  --stdb-host="$PRIVATE_HOST" --stdb-db="$PRIVATE_DB"
godot --headless --path client/godot --script res://tools/world_bindings_schema_test.gd -- \
  --cache-schema --stdb-host="$PRIVATE_HOST" --stdb-db="$PRIVATE_DB"
godot --headless --path client/godot --editor --import
godot --headless --path client/godot --script res://tools/world_bindings_schema_test.gd
```

Keep current `.gd.uid` files: regeneration overwrites scripts, not their UIDs.
Do not hand-edit generated scripts. The obsolete `ContinuumOwnRole` used to map
`my_role` and could overwrite the current `ContinuumMembership` mapping according
to directory iteration order. Both its script and UID must stay deleted.

The existing generator fetches real schema v10 with endpoint overrides that do
**not** change the saved endpoint. However, SDK codegen consumes/clears
`unparsed_module_schema`, and its parsed Resource fields are not exported.
The explicit cache helper above re-fetches and stores exact production JSON,
checks backend XY/view/XYZ indexes, excludes test-probe reducers, and verifies
Membership owns `my_role`. A second editor import followed by this check proves
the persisted cache is present and the obsolete type cannot resurrect. Neither
command changes the normal module name, URI, native pins, or Main.

## Typed checks

```sh
godot --headless --path client/godot --script res://tools/world_bindings_test.gd
godot --headless --path client/godot --script res://tools/building_properties_bindings_test.gd
HOME="$PRIVATE_HOME" godot --headless --path client/godot \
  --script res://tools/world_bindings_wire_test.gd -- \
  --stdb-host="$PRIVATE_HOST" --stdb-db="$PRIVATE_DB"
```

The offline test writes/reads actual BSATN bytes for all phase ordinals0..6,
u64 identifiers/counters, signed-i64 transport of a high-bit unsigned seed,
1024-element `i16`/`u8` source arrays including base-16, LOD3/5/7/9 overview
rows with signed cuts, empty surface-17, `u16` material and256-element arrays,
and complete4096-voxel overrides retaining explicit zero/65535 materials.
It applies rows through real local database callbacks, checks generated unique
ID indexes and exact `reset_world_large(I32,I32,U64)`/zero-argument retry calls.
The SDK only generates unique indexes; backend composite indexes are checked
against the fetched production schema rather than invented client accessors.

The isolated wire driver uses an actual generated SDK client (not Main), awaits
bootstrap and full2048 Ready, decodes the Membership view, and subscribes only to
one source/overview coordinate plus a bounded override coordinate. No terrain
table-wide subscriptions or gameplay/reset calls occur. It disables token saving
and uses the supplied private home. The parent's combined SDK/streaming/Main
end-to-end gate remains separate.

At regeneration time the unmodified SDK rejects negative signed representations
of u64 during serialization. The strict offline test intentionally exits1 at
that gate until the parallel SDK fix is integrated; all preceding schema/array/
index/reducer checks and the actual bounded production wire smoke test pass.
This is not a generated-binding workaround or a claim that Main E2E passed.
