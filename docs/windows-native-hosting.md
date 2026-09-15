# Windows Native Hosting

The Windows adapter is a per-user, Windows x86_64 implementation of the native
hosting contract. `windows-supervisor.ps1` is the only start entrypoint. It
holds a global user-SID/data-directory mutex and an exclusive lock file inside
the resolved data directory, plus a Job Object while the regular
`spacetime-x86_64-pc-windows-msvc` runtime is alive. The UI only starts or
requests the supervisor; closing the UI does not own or terminate that process.

The supervisor writes `server.json` atomically. Ownership requires the recorded
supervisor PID, Windows creation time, startup nonce, lock owner, runtime PID,
and runtime creation time. A PID by itself never authorizes health or control.
Runtime, CLI, supervisor, and module SHA-256 values are pinned. Publish runs
only when the durable module pin is absent; a different pin is refused and
requires an explicit upgrade operation. Later starts preserve the data
directory and do not republish an unchanged module.

The supervisor first detaches from any inherited console, allocates its own
hidden console, and installs a pinned ignore-control handler. The suspended
runtime inherits only that console; it is assigned to the Job Object before
resume and is not created with `CREATE_NEW_CONSOLE` or a new process group.
Graceful stop sends Ctrl+C group 0 only to this supervisor-owned console, never
by attaching to a PID or to a user console. Force stop is available only after
a timeout and only through the nonce/creation-identity checked supervisor
request. It never uses `taskkill` or a broad process match.

Autostart is an idempotent per-user Task Scheduler logon task with
`LeastPrivilege` and no boot service. Arguments are validated and XML-escaped;
the supervisor receives the manager's config directory and passes its exact
`config/cli.toml` child to the CLI, while paths are passed
as arguments rather than a shell command. Registration is verified by querying
back the task and comparing its trigger, principal, executable arguments, and
working directory; disable treats only an explicit not-found result as already
disabled.

## Common Integration

The common manager selects `ContinuumNativeServerWindowsAdapter` on Windows and
configures its persistent helper/data paths before discovery or launch. The
installer supplies `spacetimedb-standalone.exe` and `spacetimedb-cli.exe` from the
verified native archive. Missing runtime/helpers trigger preparation or an
actionable error, not a Linux fallback. The manager
adapter calls map directly to `launch`, `health`,
`is_process_identity(pid, token, binary, sha, parent=-1)`, `process_exists`,
`terminate`, `cleanup_stale`, and `set_autostart` with the existing argument
order. `runtime_path`, `cli_path`, and `helperpath` are Windows packaging
helpers. Control searches durable manifests and requires the recorded binary,
digest, PID, token, parent, and data configuration to match before routing a
request.

The manager calls `configure(supervisor, runtime, cli, data_dir,
config_dir, manifest, lock)` during setup. This binds control to
the configured manifest and data directory across UI reopen. If setup has not
provided a supervisor, the adapter only looks for the installed helper under
`%LOCALAPPDATA%\Continuum\native\helpers`; missing helper or SID resolution is
unsupported, never a username fallback.

The supervisor manifest records `runtime`, `runtime_sha256`, `cli_sha256`,
`supervisor_sha256`, `module_sha256`, `data_dir`, `database`, `host`,
`startup_nonce`, `pid`, `started_at`, `runtime_pid`, `runtime_started_at`,
`runtime_parent_pid`, `runtime_binary`, and `phase`. Process tokens are
invariant decimal Windows FILETIME creation ticks.
The common status path must use `started_at`, not infer identity from PID.

Unlike Linux's inherited-flock adoption, a Windows supervisor exit closes its
Job Object and terminates the child. The client does not pretend to adopt a
runtime whose supervising Job Object is gone. Graceful/force shutdown waits for
process disappearance and then removes metadata under the data lock.

This Linux checkout cannot prove Windows API behavior, runtime shutdown, or
Task Scheduler registration. Run
`scripts/internal/test-native-server-windows-integration.ps1` on a disposable
Windows x86_64 user account: install the pinned archive, run the adapter test,
start twice concurrently, close/reopen the UI, verify `/v1/ping`, verify one
PID and unchanged data/module pin, register/unregister logon autostart, send a
graceful stop, and verify timeout-gated force stop against a deliberately
nonresponsive test child. Record the OS build, PowerShell version, runtime
archive hash, and results.
