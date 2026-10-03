# Vendored SDK enum database keys

The pinned Flametime SDK represents Rust enums as Godot `Resource` instances.
Godot dictionaries compare those instances by object identity, not by their enum
value. Each subscription insert/delete is independently deserialized, so the
original cache implementation could insert duplicate enum-primary-key rows and
could not erase them when the server deleted them. The generated unique index
also could not find a row using a freshly constructed enum argument.

This became visible with `production_policy.resource`: the reducer successfully
removed the authoritative row, but the existing client's cache retained it and
never emitted `row_deleted`. Main's existing insert/update/delete listeners were
correct; no optimistic UI workaround or backend migration is needed.

The local vendored changes are:

- `LocalDatabase.stable_key` supports **validated unit-only enums**, not general
  payload enums. The enum script must match its schema registration; every option
  must be unit-valued, tags must be contiguous and within one byte, and the value
  must have a valid tag and null payload. It directly creates the canonical tag
  byte without calling the generic payload encoder. Integer, string and byte-array
  keys remain unchanged.
- `column_key` additionally validates the enum type against the column schema.
  Null, malformed and unsupported keys return the null sentinel; table updates,
  lookups and index handlers reject it without writes or row notifications.
  Invalid-key-only updates also suppress transaction callbacks. Generated enum
  `find(null)` returns null safely, including an index not yet connected to a DB.
- `_ModuleTableUniqueIndex` uses that same normalization for cache notifications.
- The generator emits a byte-array-keyed cache and normalized lookup for enum
  indexes while retaining the public typed `find(enum)` signature. Non-enum
  generated indexes are unchanged. Generated files are regenerated, not patched
  by hand; table declaration order can change with schema enumeration order.

## Regression checks

After `godot --headless --path client/godot --import`:

```sh
godot --headless --path client/godot --script res://tools/enum_key_cache_test.gd
godot --headless --path client/godot --script res://tools/unit_enum_key_contract_test.gd
godot --headless --path client/godot --script res://tools/production_policy_bindings_test.gd
```

The backend-free cache check uses distinct enum objects for inserts, combined
replacement transactions, deletion and lookup for every resource. It checks
row notifications, clear/reload and existing integer/string indexes.
The bounded-contract check rejects F64/I32/Bool/String payload enums (including
zero, false and empty values), mixed payload/unit enums, malformed tags/options,
unregistered types, wrong-column enum types and null. It checks distinct valid
unit keys, primitive preservation, no invalid-key writes/callbacks, and exactly
one policy query in Main.

This fix does **not** implement overlapping subscription ownership/reference
counting. That is a preexisting SDK limitation affecting primitive keys too.
The supported Main path has one policy query; the live regression intentionally
uses one policy query per connection. No serializer or subscription-refcount
rewrite is included, and general payload enum keys remain unsupported.

The real-session check accepts only explicitly supplied disposable connected-gate
QA metadata. It reads an existing admin token file without printing or saving
tokens; it does not connect to a default endpoint. The policy table must start
empty. The default probes only Meat, reproducing deletion against a second fresh
subscription; `--all-resources` additionally checks all resource variants,
updates, fresh-enum index lookups, reconnect and server/cache agreement. A passing
run leaves the table empty. If an interrupted run leaves a policy, remove that
policy explicitly on the same disposable QA server before rerunning.

```sh
godot --headless --path client/godot --script res://tools/production_policy_session_test.gd -- \
  --qa-metadata=/absolute/path/to/disposable-qa/metadata.json --all-resources
```

Verified against private QA `http://127.0.0.1:45053`, database
`connected-colony-325e69addc27`. Before the fix, removal produced an empty fresh
server snapshot but left one cached Meat row, then timed out. After regeneration
from that server's actual schema, all four variants passed with 8 inserts,
4 updates and 8 deletes (including reconnect clear/reload notifications).
No backend schema, main script or UI component changed.

The unit-only followup was regenerated from newly built WASM published to another
owned disposable native 2.10.0 server, then passed the same four-resource real
session gate. Evidence (endpoint/database, exact generator command, WASM/schema
hashes, import and test logs) is in
`/tmp/opencode/bindings-unit-schema-9qo9dhpq/`; that private server was stopped
after the gate and its policy table was verified empty.
