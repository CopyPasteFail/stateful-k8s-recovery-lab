#!/usr/bin/env bash
# run-app-local.sh — build and run the app locally using a repo-local data directory.
# Override DATA_DIR or PORT via environment variables before calling this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/app"

export PATH="/usr/local/go/bin:${PATH}"

if ! command -v go &>/dev/null; then
    printf 'ERROR: go not found. Install Go and ensure it is on PATH.\n' >&2
    exit 1
fi

DEFAULT_DATA_DIR="${REPO_ROOT}/.local/leveldb"
export DATA_DIR="${DATA_DIR:-${DEFAULT_DATA_DIR}}"
export PORT="${PORT:-8080}"

mkdir -p "${DATA_DIR}"

printf '\n=== leveldb-app (local) ===\n'
printf '  DATA_DIR : %s\n' "${DATA_DIR}"
printf '  PORT     : %s\n' "${PORT}"
printf '  Endpoints:\n'
printf '    http://localhost:%s/kv/<key>\n' "${PORT}"
printf '    http://localhost:%s/healthz\n' "${PORT}"
printf '    http://localhost:%s/metrics\n' "${PORT}"
printf '\n  Press Ctrl-C to stop.\n\n'

cd "${APP_DIR}"
exec go run ./cmd/leveldb-app
