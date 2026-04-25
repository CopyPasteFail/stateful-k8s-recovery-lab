#!/usr/bin/env bash
# test-app.sh — run Go tests for the app.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${REPO_ROOT}/app"

export PATH="/usr/local/go/bin:${PATH}"

if ! command -v go &>/dev/null; then
    printf 'ERROR: go not found. Install Go and ensure it is on PATH.\n' >&2
    exit 1
fi

printf '\n=== Go tests ===\n'
cd "${APP_DIR}"
go test -v -count=1 ./...
printf '\nAll tests passed.\n\n'
