#!/usr/bin/env bash
set -euo pipefail

cleanup_stale() {
  [[ $# -eq 4 ]] || { printf 'usage: %s cleanup LOCK MANIFEST MANIFEST_SHA256\n' "$0" >&2; exit 2; }
  local lock_path="$2" manifest_path="$3" expected_sha256="$4"
  [[ "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]] || { printf 'invalid manifest checksum\n' >&2; exit 64; }
  [[ "$lock_path" != *$'\n'* && "$lock_path" != *$'\r'* && "$lock_path" != *'"'* && "$lock_path" != *'\\'* ]] || { printf 'unsafe lock path\n' >&2; exit 64; }
  [[ "$manifest_path" != *$'\n'* && "$manifest_path" != *$'\r'* && "$manifest_path" != *'"'* && "$manifest_path" != *'\\'* ]] || { printf 'unsafe manifest path\n' >&2; exit 64; }
  mkdir -p "$(dirname "$lock_path")"
  exec 9>"$lock_path"
  flock -n 9 || exit 73
  [[ -f "$manifest_path" ]] || exit 0
  [[ "$(sha256sum "$manifest_path" | cut -d' ' -f1)" == "$expected_sha256" ]] || exit 75
  rm -f -- "$manifest_path"
  exit 0
}

if [[ "${1:-}" == cleanup ]]; then
  cleanup_stale "$@"
fi

delete_server() {
  [[ $# -eq 4 ]] || exit 64
  local lock_path="$2" manifest_path="$3" instance="$4"
  [[ "$instance" == /* && "$instance" != / && "$(realpath -m -- "$instance")" == "$instance" ]] || { printf 'unsafe server directory\n' >&2; exit 64; }
  [[ "$lock_path" == "$instance/data.lock" && "$manifest_path" == "$instance/server.json" ]] || exit 64
  for value in "$instance/data" "$instance/config" "$lock_path" "$manifest_path" "$instance/.continuum-deleted" "$instance/continuum_module.wasm"; do
    [[ ! -L "$value" ]] || { printf 'refusing redirected server paths\n' >&2; exit 64; }
  done
  mkdir -p -- "$instance"
  exec 9>"$lock_path"
  flock -n 9 || { printf 'server is still locked\n' >&2; exit 73; }
  [[ ! -e "$manifest_path" ]] || { printf 'server ownership metadata still exists\n' >&2; exit 73; }
  # Keep the lock inode and a durable tombstone. A supervisor already waiting on
  # this lock must refuse startup, not recreate a deleted colony after unlock.
  printf 'deleted\n' >"$instance/.continuum-deleted"
  rm -rf -- "$instance/data" "$instance/config"
  rm -f -- "$instance/server.log" "$instance/server.log.cli" "$instance/server.log.cli.err" "$instance/continuum_module.wasm"
  exit 0
}

if [[ "${1:-}" == delete ]]; then
  delete_server "$@"
fi

install_module() {
  [[ $# -eq 6 ]] || exit 64
  local lock_path="$2" manifest_path="$3" instance="$4" source="$5" digest="$6"
  [[ "$instance" == /* && "$instance" != / && "$(realpath -m -- "$instance")" == "$instance" ]] || { printf 'unsafe server directory\n' >&2; exit 64; }
  [[ "$lock_path" == "$instance/data.lock" && "$manifest_path" == "$instance/server.json" && "$digest" =~ ^[0-9a-f]{64}$ ]] || exit 64
  for value in "$instance" "$source"; do
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'"'* && "$value" != *'\\'* ]] || exit 64
  done
  local destination="$instance/continuum_module.wasm"
  for value in "$instance/data" "$instance/config" "$lock_path" "$manifest_path" "$destination" "$instance/.continuum-deleted" "$source"; do
    [[ ! -L "$value" ]] || { printf 'refusing redirected module paths\n' >&2; exit 64; }
  done
  [[ -f "$source" ]] || exit 66
  mkdir -p -- "$instance"
  exec 9>>"$lock_path"
  flock -n 9 || { printf 'server is still locked\n' >&2; exit 73; }
  [[ ! -e "$manifest_path" ]] || { printf 'server ownership metadata still exists\n' >&2; exit 73; }
  [[ ! -e "$instance/.continuum-deleted" ]] || { printf 'this managed server was deleted\n' >&2; exit 66; }
  local temporary
  temporary="$(mktemp -- "$destination.tmp.XXXXXXXX")"
  trap 'rm -f -- "$temporary"' EXIT
  cp -- "$source" "$temporary"
  [[ "$(sha256sum "$temporary" | cut -d' ' -f1)" == "$digest" ]] || { printf 'module checksum mismatch\n' >&2; exit 65; }
  mv -f -- "$temporary" "$destination"
  trap - EXIT
  exit 0
}

if [[ "${1:-}" == install-module ]]; then
  install_module "$@"
fi

usage() { printf 'usage: %s start RUNTIME CLI MODULE HOST DATABASE DATA CONFIG LOCK LOG MANIFEST MODULE_SHA256 STARTUP_NONCE\n' "$0" >&2; exit 2; }
[[ "${1:-}" == start && $# -eq 13 ]] || usage
runtime="$2"; cli="$3"; module="$4"; host="$5"; database="$6"; data="$7"; config="$8"; lock="$9"; log="${10}"; manifest="${11}"; module_sha256="${12}"; startup_nonce="${13}"
umask 077
[[ "$host" =~ ^127\.0\.0\.1:([1-9][0-9]{3,4})$ && "${BASH_REMATCH[1]}" -ge 1024 && "${BASH_REMATCH[1]}" -le 65535 ]] || { printf 'refusing non-local bind: %s\n' "$host" >&2; exit 64; }
[[ "$database" =~ ^[A-Za-z0-9_-]+$ ]] || { printf 'invalid database name\n' >&2; exit 64; }
[[ -x "$runtime" && -x "$cli" && -f "$module" ]] || { printf 'native distribution is incomplete\n' >&2; exit 127; }
[[ "$module_sha256" =~ ^[0-9a-fA-F]{64}$ && "$startup_nonce" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'invalid startup identity\n' >&2; exit 64; }
for value in "$runtime" "$cli" "$module" "$data" "$config" "$lock" "$log" "$manifest"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'"'* && "$value" != *'\\'* ]] || { printf 'unsafe path argument\n' >&2; exit 64; }
done
mkdir -p "$data" "$config" "$(dirname "$lock")" "$(dirname "$log")" "$(dirname "$manifest")"
exec 9>"$lock"
flock -n 9 || { printf 'native server lock is already held\n' >&2; exit 73; }
[[ ! -e "$(dirname "$manifest")/.continuum-deleted" ]] || { printf 'this managed server was deleted\n' >&2; exit 66; }
profile_module="$(dirname "$manifest")/continuum_module.wasm"
explicit_update=false
if [[ -f "$profile_module" ]]; then
  [[ ! -L "$profile_module" ]] || { printf 'refusing redirected module path\n' >&2; exit 64; }
  module="$profile_module"
  module_sha256="$(sha256sum "$module" | cut -d' ' -f1)"
  explicit_update=true
fi
[[ "$(sha256sum "$module" | cut -d' ' -f1)" == "$module_sha256" ]] || { printf 'module checksum mismatch\n' >&2; exit 65; }
if [[ -s "$data/.continuum-module.sha256" && "$(<"$data/.continuum-module.sha256")" != "$module_sha256" ]]; then
  if [[ "$explicit_update" != true ]]; then
    printf 'installed module digest differs; explicit upgrade is required\n' >&2
    exit 66
  fi
fi
if curl --silent --output /dev/null --connect-timeout 1 --max-time 1 "http://$host/v1/ping"; then
  printf 'native endpoint is already occupied by an unowned server\n' >&2
  exit 73
fi
# Keep the lock in this supervisor for the entire runtime lifetime. The child
# is deliberately one known PID: shutdown forwards only to that child, never to
# an arbitrary process group.
runtime_sha256="$(sha256sum "$runtime" | cut -d' ' -f1)"
cli_sha256="$(sha256sum "$cli" | cut -d' ' -f1)"
supervisor_sha256="$(sha256sum "$0" | cut -d' ' -f1)"
start_token="$(awk '{print $22}' "/proc/$$/stat")"
tmp_manifest="${manifest}.tmp.$$"
exec >>"$log" 2>&1

child_pid=""
shutdown_requested=false
stop_child() {
  if [[ "$child_pid" =~ ^[0-9]+$ ]] && (( child_pid > 1 )) && kill -0 "$child_pid" 2>/dev/null; then
    kill -INT -- "$child_pid" 2>/dev/null || true
    for _ in {1..50}; do
      kill -0 "$child_pid" 2>/dev/null || break
      sleep 0.1 9>&-
    done
    if kill -0 "$child_pid" 2>/dev/null; then
      printf 'native runtime did not stop after SIGINT\n' >&2
      write_manifest stop_timeout
    fi
    wait "$child_pid" 2>/dev/null || true
  fi
}
forward_signal() {
  shutdown_requested=true
  if [[ "$child_pid" =~ ^[0-9]+$ ]] && (( child_pid > 1 )) && kill -0 "$child_pid" 2>/dev/null; then
    write_manifest stopping
    kill -INT -- "$child_pid" 2>/dev/null || true
  fi
  exit 0
}
trap 'stop_child' EXIT
trap 'forward_signal' INT TERM

write_manifest() {
  local phase="$1"
  runtime_started_at=""
  for _ in {1..50}; do
    runtime_started_at="$(awk '{print $22}' "/proc/$child_pid/stat" 9>&- 2>/dev/null || true)"
    [[ "$runtime_started_at" =~ ^[0-9]+$ ]] && break
    sleep 0.01 9>&-
  done
  [[ "$runtime_started_at" =~ ^[0-9]+$ ]] || { printf 'runtime start identity unavailable\n' >&2; exit 125; }
  printf '{"phase":"%s","runtime":"2.10.0","runtime_sha256":"%s","cli_sha256":"%s","supervisor_sha256":"%s","module_sha256":"%s","database":"%s","pid":%s,"runtime_pid":%s,"started_at":"%s","runtime_started_at":"%s","runtime_parent_pid":%s,"runtime_binary":"%s","startup_nonce":"%s","data_dir":"%s","host":"http://%s"}\n' \
    "$phase" "$runtime_sha256" "$cli_sha256" "$supervisor_sha256" "$module_sha256" "$database" "$$" "$child_pid" "$start_token" "$runtime_started_at" "$$" "$runtime" "$startup_nonce" "$data" "$host" > "$tmp_manifest"
  mv -f -- "$tmp_manifest" "$manifest" 9>&-
}

env XDG_CONFIG_HOME="$config" "$runtime" start --listen-addr "$host" --data-dir "$data" --jwt-key-dir "$config" &
child_pid=$!
write_manifest provisioning

health_deadline=$((SECONDS + 120))
until curl --silent --fail --connect-timeout 1 --max-time 1 "http://$host/v1/ping" 9>&- >/dev/null; do
  if (( SECONDS >= health_deadline )); then
    printf 'native runtime did not become healthy before provisioning deadline\n' >&2
    exit 124
  fi
  if ! kill -0 "$child_pid" 2>/dev/null; then
    wait "$child_pid" 2>/dev/null || true
    printf 'native runtime exited before becoming healthy\n' >&2
    exit 125
  fi
  sleep 1 9>&-
done

kill -0 "$child_pid" 2>/dev/null || { printf 'owned runtime exited before publication\n' >&2; exit 125; }
if [[ ! -s "$data/.continuum-module.sha256" || "$(<"$data/.continuum-module.sha256")" != "$module_sha256" ]]; then
  XDG_CONFIG_HOME="$config" "$cli" publish --server "http://$host" --yes --delete-data=never -b "$module" "$database" 9>&-
  printf '%s' "$module_sha256" > "$data/.continuum-module.sha256"
fi
write_manifest running
for _ in {1..50}; do
  kill -0 "$child_pid" 2>/dev/null || break
  sleep 0.1 9>&-
done
set +e
wait "$child_pid"
child_rc=$?
set -e
exit "$child_rc"
