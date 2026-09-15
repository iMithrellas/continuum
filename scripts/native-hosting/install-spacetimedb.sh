#!/usr/bin/env bash
set -euo pipefail
# Downloads only the pinned, hash-verified upstream archive. It never pipes a
# remote script to a shell and never replaces an existing version.
VERSION="2.10.0"
URL="https://github.com/clockworklabs/SpacetimeDB/releases/download/v${VERSION}/spacetime-x86_64-unknown-linux-gnu.tar.gz"
SHA256="2188099ab1dde4a9a0ca88334fb10440eb9509bdcae93b4ef1147c7a66c8e702"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DEST="${1:-${CONTINUUM_NATIVE_HOME:-$DATA_HOME/Continuum/native/spacetimedb/${VERSION}}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$DEST"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [[ -n "${CONTINUUM_NATIVE_ARCHIVE:-}" ]]; then
  [[ -f "$CONTINUUM_NATIVE_ARCHIVE" ]] || { printf 'native archive input is missing: %s\n' "$CONTINUUM_NATIVE_ARCHIVE" >&2; exit 66; }
  cp -- "$CONTINUUM_NATIVE_ARCHIVE" "$tmp"
else
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 --retry 2 --retry-delay 2 --retry-connrefused "$URL" -o "$tmp"
fi
printf '%s  %s\n' "$SHA256" "$tmp" | sha256sum --check --status
tar -xzf "$tmp" -C "$DEST"
install -m 0755 "$SCRIPT_DIR/native-server-supervisor.sh" "$DEST/native-server-supervisor.sh"
install -m 0755 "$SCRIPT_DIR/native-server-provisioner.sh" "$DEST/native-server-provisioner.sh"
[[ -x "$DEST/spacetimedb-standalone" && -x "$DEST/spacetimedb-cli" ]] || {
  printf 'pinned archive did not contain executable SpacetimeDB runtime and CLI\n' >&2
  exit 127
}
