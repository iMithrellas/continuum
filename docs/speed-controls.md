# Speed Controls

The server exposes one public singleton table, `speed_control`:

| Field | Wire type | Meaning |
| --- | --- | --- |
| `id` | `u32` primary key | Always `0` |
| `cooldown_seconds` | `u32` | Admin policy, `0..=3600`; `0` disables cooldown |
| `last_changed_at` | `Option<Timestamp>` | Real wall-clock time of the last actual speed change |

The admin-only reducers are:

- `set_time_scale(time_scale: f64) -> Result<(), String>` accepts finite values
  from `0` through `100000`.
- `set_speed_change_cooldown(cooldown_seconds: u32) -> Result<(), String>` accepts
  `0` through `3600`.

Speed cooldown uses the reducer timestamp, not `game_seconds`, so pausing the
simulation does not pause the cooldown. A rejected speed change leaves every
row unchanged. Setting the current speed is an idempotent no-op and does not
consume cooldown or write an event. A successful actual speed change records
`last_changed_at` even when cooldown is disabled. Changing the cooldown policy
does not change `last_changed_at`; equal policy values are no-ops.

An additive schema update with no `speed_control` row behaves as
`cooldown_seconds = 0` and `last_changed_at = None` until the first write.
`init` and `reset_colony` explicitly seed/reset the row to that disabled state.

Use the repository recipes from the repository root:

```sh
just stdb call continuum set_speed_change_cooldown 300
just stdb call continuum set_time_scale 12
```

The headless smoke test does not require admin access and accepts a missing row
for legacy databases. Against an isolated database with a configured row, ask
an admin to authorize the temporary smoke identity with `set_operator`, then
run the test against that already prepared database:

```sh
just smoke-existing --stdb-db=continuum-worker-cooldown --expected-speed-cooldown=5
```

Do not use `just smoke` for this target: `smoke` first prepares and publishes the
local default `continuum` database. `smoke-existing` performs no preparation, so
the server, database, and generated bindings must already match.
Omit `--expected-speed-cooldown` to exercise the missing-row compatibility path.
