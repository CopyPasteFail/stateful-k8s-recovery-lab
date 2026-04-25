#!/usr/bin/env bash
# seed-data.sh — write a deterministic set of key-value pairs to the running app.
#
# Seeds four well-known keys so that a subsequent backup/restore can be
# verified against the same values.
#
# Usage: make seed-data
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

LOCAL_PORT=18081
BASE="http://localhost:${LOCAL_PORT}"
PF_PID=""

require kubectl
require curl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: seed-data ==='

# ── Cleanup on exit ───────────────────────────────────────────────────────────

_cleanup() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
    fi
}
trap _cleanup EXIT

# ── Pre-flight ────────────────────────────────────────────────────────────────

section "Pre-flight"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    die "Namespace '${NS_APP}' not found. Run: make deploy"
fi

APP_POD="$(kubectl get pods -n "${NS_APP}" \
    -l "app.kubernetes.io/name=leveldb-app" \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)"

if [[ -z "${APP_POD}" ]]; then
    die "No app pod found. Run: make deploy"
fi
ok "Pod: ${APP_POD}"

# ── Port-forward ──────────────────────────────────────────────────────────────

section "Port-forward"

kubectl port-forward "pod/${APP_POD}" "${LOCAL_PORT}:8080" \
    --namespace "${NS_APP}" &>/dev/null &
PF_PID=$!

for i in $(seq 1 10); do
    if curl -sf "${BASE}/healthz" &>/dev/null; then
        break
    fi
    if [[ "${i}" -eq 10 ]]; then
        die "Port-forward did not become ready after 10s"
    fi
    sleep 1
done
ok "Port-forward ready on localhost:${LOCAL_PORT}"

# ── Seed keys ─────────────────────────────────────────────────────────────────

section "Writing seed keys"

SEEDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

declare -A SEED_DATA=(
    [environment]="lab"
    [version]="v1"
    [cluster]="${CLUSTER_NAME}"
    [seeded-at]="${SEEDED_AT}"
)

for key in environment version cluster seeded-at; do
    val="${SEED_DATA[${key}]}"
    HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
        -X PUT "${BASE}/kv/${key}" \
        -H "Content-Type: text/plain" \
        --data-raw "${val}")"
    if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "204" && "${HTTP_STATUS}" != "201" ]]; then
        die "PUT /kv/${key} returned HTTP ${HTTP_STATUS}"
    fi
    ok "PUT /kv/${key} = '${val}'"
done

# ── Verify ────────────────────────────────────────────────────────────────────

section "Verifying seed keys"

for key in environment version cluster seeded-at; do
    got="$(curl -sf "${BASE}/kv/${key}" 2>/dev/null || true)"
    expected="${SEED_DATA[${key}]}"
    if [[ "${got}" != "${expected}" ]]; then
        die "GET /kv/${key}: expected '${expected}', got '${got}'"
    fi
    ok "GET /kv/${key} = '${got}'"
done

# ── Done ─────────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    "Seed data written at ${SEEDED_AT}." \
    '' \
    'Read back with:' \
    "  make port-forward TARGET=app" \
    "  curl http://localhost:8080/kv/environment" \
    "  curl http://localhost:8080/kv/seeded-at" \
    ''
