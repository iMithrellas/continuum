# Ecological production

This is an intentional gameplay change for **live existing worlds**, not only
new colonies. Every live load copies existing authoritative `Terrain` rows by
durable `tile_id`. Those values now affect food, wood, and meat produced at that
tile. Existing terrain backfill remains unchanged; production never regenerates
fields or uses actor-dependent randomness. No public/wire schema, migration,
client binding, work permission, scheduling, or hauling change is required.

## Formula for client labels

`sim::ecology::production_multiplier(work, terrain)` is the pure server API.
For each relevant field, first normalize finite values with `clamp(value, 0, 1)`;
normalize NaN and either infinity to zero (conservative poor suitability).

| Work | Yield multiplier | Possible future label |
| --- | --- | --- |
| Farming | `0.5 + soil_fertility * moisture` | Farming yield |
| Logging | `0.5 + forest_density` | Logging yield |
| Hunting | `0.5 + forest_density` | Hunting yield |
| Mining / None | `1.0` | Unaffected |

All ecological multipliers are finite and bounded in `[0.5, 1.5]`. Fertility and
moisture are both necessary for farming's bonus; denser forest helps both wood
and game yields. No depletion, seasonality, regeneration, or optimal-moisture
curve is implied. A label can show `100 * multiplier` percent of baseline yield.
It must use persisted terrain for the selected tile ID, not resample the seed.
Missing terrain is **exactly `1.0`**, not poor terrain. Historical `new_world()`
fixtures deliberately have an empty ecological map, keeping golden traces intact.

Production is `baseline_output_per_hour * (productivity / 100) * hours * multiplier`.
Output still lands in a ground pile and is unavailable in colony stores until
picked up and delivered. Ecology does not multiply cargo or deposits: hauling
conserves the amount already produced. Disabled facilities/orders and dedicated
hauler roles retain their existing production restrictions. For facilities with
footprints, ecology uses the operational tile's durable ID, not footprint averages
or the actor's current collection index.
