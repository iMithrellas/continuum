# Native Hosting Contract

Each `ContinuumNativeServerManager` owns one physical SpacetimeDB server and one
module database. The game UI can manage up to 16 independent, named local server
profiles, each with a separate loopback port, data directory, configuration, log,
lock, and ownership manifest. Multiple servers can run simultaneously. A manager
still has no world parameter: logical worlds within a server remain namespaces/
rows in its database, not separate processes.

`ContinuumNativeServerCatalog` persists profile IDs, display names, and ports in
`<native-root>/servers.json`. The original `default` server is adopted in place
at port 3001 with its existing `<native-root>/2.10.0` files. Additional profiles
use `<native-root>/servers/<generated-id>` and automatically allocated ports
starting at 3001 (skipping ports reserved by other profiles). Paths are derived
from validated generated IDs, never accepted from the catalog. Runtime binaries
and the legacy pinned module artifact are shared. New profiles stage a separate control
helper so adding a server does not overwrite an old running supervisor's identity.
First-use preparation and explicit updates use each profile's own `continuum_module.wasm` and
a separately staged `module-updates-v1` helper. Updating one server never changes
the shared artifact or the executable hashes of another running server.
An existing malformed catalog fails closed; an empty catalog stays empty on reopen.

## Integration API

- `status()` returns `unknown`, `checking`, `offline`, `starting`, `online`,
  `unhealthy`, `stopping`, `stop_timeout`, `unsupported`, `conflict`, `installing`,
  `preparing`, `deleting`, or `deleted`.
- `configure_instance(id, port)` selects a profile before any lifecycle operation.
- `start()` is idempotent for an already healthy owned server and emits
  `progress`, `ready(host, database)`, or `failed(message)`.
- `tick()` must be called by the owning Godot node while starting/stopping.
- `can_stop()` is true only after PID, start-token, and executable ownership
  validation; an owned unhealthy server remains stoppable but never restartable.
- `stop(false)` requests graceful termination only. A `stop_timeout` status is
  the only point at which UI may ask for explicit confirmation and call
  `stop(true)`.
  Explicit requests re-read ownership and target the verified current supervisor
  (or adoptable runtime), never a cached PID/start token from before an update.
  Failed ownership checks report a refusal instead of silently dropping a click.
- `set_autostart(enabled)` uses the same supervisor command as `start()` and
  registers a Linux user-systemd service or a Windows per-user logon task.
- `get_autostart()` reads actual OS registration state; client preferences do not
  silently register or unregister a service when the menu opens.
- `delete_data()` requires an offline server (or a retry of an already-deleted
  profile), validates its exact derived paths, disables only its login startup,
  and removes its colony data, configuration, and logs under the runtime's OS
  lock. Live/ambiguous manifests, held locks, or redirected paths refuse deletion.
  A retained lock inode and `.continuum-deleted` tombstone prevent stale current
  controllers from recreating the deleted colony. No force-stop is implicit.
  The catalog entry is removed only after successful deletion; a failed catalog
  write leaves an explicit retryable entry rather than pretending success.
- `update_module()` requires an offline server with no remaining ownership
  manifest. It builds the current checkout (not a stale export/Cargo artifact),
  or uses the current exported build's packaged module. Installation of the
  per-profile artifact takes the runtime's OS lock and refuses redirected paths,
  manifests, held locks, and deleted profiles. It neither starts nor joins.
  An existing login startup registration is disabled before installation and
  restored with the updated helper/module; restoration failures are visible.

The manager does not stop a server when the UI exits. A new manager reads the
durable manifest and rediscovers a still-owned, healthy process. The supervisor
owns the OS lock before either provisioning or runtime launch, and atomically
writes `provisioning` and `starting` manifests before handing the lock FD to the
runtime. A stale manifest is never enough to authorize health or termination.
Manifest cleanup requires the same manager startup nonce, matching PID/token,
and confirmed process absence, so a conflict cannot erase another manager's
metadata.

The **Servers** UI lists every profile and its cached state. **Manage** selects
the target of start/join, stop, force-stop, login startup, and deletion controls.
Both destructive confirmations capture the exact controller, not mutable UI
selection. Stopping a server disconnects the client only when it is connected
to that server. Delete is offered only once the selected server is stopped and
requires an explicit permanent-data confirmation. Remote saved connections
have no process/deletion capabilities. Removing history never deletes colony
data. Successful local deletion also removes that endpoint's history/favorites,
clears **Join last server** if it pointed there, and leaves shared runtime/module
files and other profiles untouched.

**Update module…** requires a stopped-server confirmation and prepares an update
only for the captured controller, even if selection changes. **Start local server**
then publishes the new digest with `--delete-data=never`. Compatible additive
schema updates keep existing rows; changes requiring a reset fail rather than
wiping the colony. Failed publication retains the last deployed digest for retry.
Ordinary restarts skip publication when that digest still matches. Subscription
rejections (including missing tables) show the server's error in **Servers** or
the main menu immediately, release connection busy state, and do not loop automatic
rejoins. Missing-table guidance names the stopped-server update workflow.

Client credential caches include both the managed server's durable profile ID
and the normal/admin/developer client profile. A recreated server gets a new
cache even when it reuses the same loopback port. Known localhost/loopback aliases
resolve to the same managed cache, independently of the UI's selected server.
Old endpoint-only tokens remain untouched and are migration candidates only if
`POST /v1/identity/websocket-token` authenticates them against that server. The
60-second response token is discarded; the original durable token/identity is
retained, preserving existing role grants across module updates and restarts.
Only a 401 on a managed target authorizes obtaining a fresh anonymous identity;
transport/server failures do not reset caches. Remote authentication failures
are terminal and never silently replace an identity or loop automatic retries.
Token acquisition/validation has a bounded HTTP timeout. The admin bootstrap
and authorization probe use the same credential resolver as the main UI.

The controller's cancellation epoch invalidates queued startup and autojoin.
An already-running atomic installation/build finishes within its timeout, but
cannot proceed into later stages after cancellation. The application polls for
worker completion while continuing to render instead of synchronously waiting in
the window-close handler. This does not force-kill the managed game server.

## Native UI Scope

The Linux x86_64 native lifecycle is exposed through a root-owned worker
controller per profile. UI operations are serialized per controller and
non-blocking; first-use setup is gated by the UI to avoid concurrent shared
installation/build requests, and a shared worker-side mutex serializes that
preparation even before UI status arrives. Status and health
inspection are cached at no more than once per second. Any runtime, signal, crash, or shutdown validation
must run only inside a uniquely named disposable Docker container with a
separate PID namespace, no privileged mode, no host networking, no host
filesystem mounts, and no Docker socket. Host process signals are forbidden.
The Windows adapter is wired into the same controller with Windows-specific
paths, FILETIME process identities, a dedicated console, and owned Job Objects.
Its real Windows OS/logon validation is still outstanding; Linux-safe helper
tests do not establish Windows runtime behavior.

`just test-managed-servers` checks profile persistence, isolated paths/ports,
multi-server UI lifecycle and confirmation targeting using fake managers, plus
disposable file/lock-only Linux deletion and module-installation safety checks. It launches no real
runtime and sends no host process signals. These checks do not replace the
isolated real-runtime integration gate.
It also exercises real credential HTTP requests against an owned loopback
fixture (valid legacy migration, reused-port rejection/recovery, remote refusal,
failed recovery/retry, one-time tokens, and malformed/unavailable responses).
The update/join/stop regression uses the real manager with file helpers and a
recording process adapter; it does not establish actual runtime signal behavior.

## Verified distribution

SpacetimeDB `v2.10.0` upstream release assets provide native archives for
`x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`. The distribution
manifest records their SHA-256 hashes and the installers verify those hashes;
they do not execute a downloaded script. The runtime is launched with the
documented `start --listen-addr --data-dir --jwt-key-dir` flags.

The capability gate supports Linux GNU x86_64 (including the Arch development
host) and Windows x86_64. The pinned Windows archive contains
`spacetimedb-standalone.exe` and `spacetimedb-cli.exe`; hashes and archive contents
were verified. macOS and other architectures report fallback guidance. Exported
clients require packaged module/installer assets; source checkouts build their
current module once instead of trusting a stale Cargo output file.
`just prepare-native-export` generates those assets, and both export presets
include them. PCK resources are copied to a bootstrap directory before invoking
an OS interpreter; resource URIs are never passed as executable filenames.

The integration worker must provide `module_artifact`, `cli_executable`, and
`executable` from the packaged distribution. The manager does not rebuild or
republish on ordinary starts: the locked supervisor provisions once when its
durable module digest pin is absent. The manifest records SHA-256 digests for
both runtime and module; identity is never based on a path or file length.
Only the explicit stopped-server update operation authorizes publication of a
different module. Neither preparation nor a failed publish changes the deployed
digest pin; only successful non-destructive publication writes the new pin.
