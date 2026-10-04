# Continuum

Continuum is a persistent multiplayer colony simulation: an authoritative Rust
simulation runs in SpacetimeDB, with a Godot client. Its finite, excavatable
world is built from 0.5 m cells.

## Play

Requirements: Godot 4.7 and [just](https://just.systems/). On Linux x86_64, the
client can also manage a local SpacetimeDB server. Alternatively, connect to an
existing server.

1. On a fresh checkout, build the module and import the Godot project (see
   [Build](#build) below).
2. Launch the client with `just run`.
3. In **Servers**, select a managed local server and choose **Start local server**
   (or **Join local server** if it is already running). Use **Create server** with
   a name to add another independent colony; each server has its own port and
   save data, and several can run at once. To join an existing server instead, choose **Join**
   and enter its host and database (the default database is `continuum`).

Select **Manage** beside a local server to control it. **Stop local** shuts down
only that server and keeps its colony data. Once stopped, **Delete server…** asks
for confirmation before permanently removing that server's colony, configuration,
and logs. This cannot be undone. **Remove history** only removes a saved connection;
it does not stop or delete a server. Remote servers cannot be stopped or deleted
through these local controls.

If Join reports a missing table such as `production_policy`, the server module
does not match the client. Restart the client to load the latest UI, then select
the affected server and use **Stop local → Update module… → Start local server**.
This prepares the current module and publishes it without deleting colony data;
incompatible changes fail rather than resetting the save. Other servers are not
updated or stopped.

Managed servers keep separate client credentials, even when a deleted server's
port is reused. Existing identities are migrated only after server verification;
a recreated local server obtains its own identity automatically. Authentication
errors are not module errors, and updating a module does not reset credentials.

Local server data persists after the client closes. Fresh worlds target
2048 × 2048 cells with the starter colony near the centre. The server prepares
the full world before play; the client shows its current generation phase and
progress. Disconnecting leaves the client session but does not cancel
server-side generation. Once the new world is ready, ordinary restarts preserve
it and do not regenerate it. This development release may replace an older
colony with a fresh world; backward compatibility with old saves is not
promised. Larger production worlds remain a future direction; performance at
those scales is not established.

## Roles

Authenticated players join as operators and can manage the colony. An existing
admin can assign explicit read-only Viewer access with `set_operator(identity,
false)` and restore Operator with `true`. Speed/pause and server administration
remain Admin-only. Developer and
admin are separate local client profiles, not server permissions.

To bootstrap the first admin on a local server, first start it from the normal
client, then run `just admin-grant` and confirm the grant. Thereafter use
`just admin` to open the admin client; it connects with the existing admin
identity and does not grant access. For a remote server, pass
`--stdb-host=<server-url> --stdb-db=<database>` to `just admin`. Remote grants
also require `CONTINUUM_PUBLISHER_HOST` to match that server and `CONTINUUM_STDB`
to identify an already-authorized publisher CLI; bootstrap only servers you own.

Run `just run --profile=developer` for the separate local developer UI profile.
Its F10 panel offers local diagnostics and debug utilities; it does not grant
admin or operator permissions. The F9 admin panel is available only to a
server-authorized admin.

## Build

Install Rust via [rustup](https://rustup.rs/), then add the WebAssembly target
and build the SpacetimeDB module:

```sh
rustup target add wasm32-unknown-unknown
just wasm
```

Import Godot assets after the first checkout (or after changing imported
assets/scripts):

```sh
godot --headless --editor --path client/godot --import
```

Then launch with `just run`. Docker Compose is optional for development with
the Docker-managed server; it is not needed for ordinary play or the local
native server manager.

To prepare a standalone native client export, run `just prepare-native-export`,
then export with Godot using the Linux or Windows preset in
`client/godot/export_presets.cfg`. Matching Godot export templates are required.

## More

For a first run through the current connected gameplay loop, see
[Playing the slice](docs/playing-the-slice.md).
For the player workflow around rooms, Zones, world preparation, and map zoom,
see [World, rooms, and work areas](docs/world-and-construction.md). The
[large-map client guide](docs/large-map-client.md) describes the map's overview
and detail behavior. For the corresponding implementation references, see
[building properties](docs/building-properties.md) and [world art](docs/world-art.md).

See [docs/simulation-architecture.md](docs/simulation-architecture.md) for the
simulation overview, [docs/API.md](docs/API.md) for reducers and authorization,
[docs/native-hosting-contract.md](docs/native-hosting-contract.md) for local
server details, and [UI redesign](docs/ui-redesign.md) for `ui/theme`,
`ui/components`, and UI verification commands.
