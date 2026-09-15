# Native Hosting Contract

`ContinuumNativeServerManager` owns one physical SpacetimeDB server and one
logical module database. It has no world parameter: multiple logical worlds
must remain namespaces/rows in that database, never separate processes or data
directories.

## Integration API

- `status()` returns `unknown`, `checking`, `offline`, `starting`, `online`,
  `unhealthy`, `stopping`, `stop_timeout`, `unsupported`, or `conflict`.
- `start()` is idempotent for an already healthy owned server and emits
  `progress`, `ready(host, database)`, or `failed(message)`.
- `tick()` must be called by the owning Godot node while starting/stopping.
- `can_stop()` is true only after PID, start-token, and executable ownership
  validation; an owned unhealthy server remains stoppable but never restartable.
- `stop(false)` requests graceful termination only. A `stop_timeout` status is
  the only point at which UI may ask for explicit confirmation and call
  `stop(true)`.
- `set_autostart(enabled)` uses the same supervisor command as `start()` and
  registers a Linux user-systemd service or a Windows per-user logon task.
- `get_autostart()` reads actual OS registration state; client preferences do not
  silently register or unregister a service when the menu opens.

The manager does not stop a server when the UI exits. A new manager reads the
durable manifest and rediscovers a still-owned, healthy process. The supervisor
owns the OS lock before either provisioning or runtime launch, and atomically
writes `provisioning` and `starting` manifests before handing the lock FD to the
runtime. A stale manifest is never enough to authorize health or termination.
Manifest cleanup requires the same manager startup nonce, matching PID/token,
and confirmed process absence, so a conflict cannot erase another manager's
metadata.

The controller's cancellation epoch invalidates queued startup and autojoin.
An already-running atomic installation/build finishes within its timeout, but
cannot proceed into later stages after cancellation. The application polls for
worker completion while continuing to render instead of synchronously waiting in
the window-close handler. This does not force-kill the managed game server.

## Native UI Scope

The Linux x86_64 native lifecycle is exposed through a root-owned worker
controller. UI operations are serialized and non-blocking; status and health
inspection are cached at no more than once per second. Any runtime, signal, crash, or shutdown validation
must run only inside a uniquely named disposable Docker container with a
separate PID namespace, no privileged mode, no host networking, no host
filesystem mounts, and no Docker socket. Host process signals are forbidden.
The Windows adapter is wired into the same controller with Windows-specific
paths, FILETIME process identities, a dedicated console, and owned Job Objects.
Its real Windows OS/logon validation is still outstanding; Linux-safe helper
tests do not establish Windows runtime behavior.

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
Explicit upgrade/migration UX is intentionally a later operation and must
change that pin deliberately.
