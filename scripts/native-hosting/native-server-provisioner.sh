#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 5 ]] || { printf 'usage: %s CLI CONFIG HOST MODULE DATABASE\n' "$0" >&2; exit 2; }
cli="$1"; config="$2"; host="$3"; module="$4"; database="$5"
[[ "$host" == http://127.0.0.1:3001 ]] || { printf 'refusing non-local server: %s\n' "$host" >&2; exit 64; }
[[ -x "$cli" && -f "$module" ]] || exit 127
mkdir -p "$config"
XDG_CONFIG_HOME="$config" "$cli" publish --server "$host" --yes -b "$module" "$database"
