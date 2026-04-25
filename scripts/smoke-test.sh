#!/usr/bin/env bash
# smoke-test.sh — end-to-end sanity check against the deployed app.
#
# Starts an ephemeral port-forward on localhost:18080, runs a PUT/GET/DELETE
# round-trip plus probe endpoint checks, then tears down the forward.
#
# Usage: make smoke-test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

LOCAL_PORT=18080
BASE="http://localhost:${LOCAL_PORT}"
PF_PID=""

require kubectl
require curl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: smoke-test ==='

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

POD_PHASE="$(kubectl get pod "${APP_POD}" -n "${NS_APP}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"

if [[ "${POD_PHASE}" != "Running" ]]; then
    die "Pod '${APP_POD}' is in phase '${POD_PHASE}', expected 'Running'."
fi
ok "Pod '${APP_POD}' is Running"

# ── Port-forward ──────────────────────────────────────────────────────────────

section "Port-forward"

kubectl port-forward "pod/${APP_POD}" "${LOCAL_PORT}:8080" \
    --namespace "${NS_APP}" &>/dev/null &
PF_PID=$!

# Wait for the forward to be ready (up to 10s)
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

# ── Probe endpoints ───────────────────────────────────────────────────────────

section "Probe endpoints"

_check_http() {
    local label="$1" url="$2" expected_status="$3"
    actual="$(curl -s -o /dev/null -w '%{http_code}' "${url}")"
    if [[ "${actual}" == "${expected_status}" ]]; then
        ok "${label} → HTTP ${actual}"
    else
        die "${label}: expected HTTP ${expected_status}, got HTTP ${actual}"
    fi
}

_check_http "/healthz" "${BASE}/healthz" "200"
_check_http "/readyz"  "${BASE}/readyz"  "200"
_check_http "/metrics" "${BASE}/metrics" "200"

# ── KV round-trip ─────────────────────────────────────────────────────────────

section "KV round-trip"

TEST_KEY="smoke-test-key"
TEST_VAL="smoke-test-value-$$"

# PUT
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${BASE}/kv/${TEST_KEY}" \
    -H "Content-Type: text/plain" \
    --data-raw "${TEST_VAL}")"
if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "204" && "${HTTP_STATUS}" != "201" ]]; then
    die "PUT /kv/${TEST_KEY} returned HTTP ${HTTP_STATUS}"
fi
ok "PUT /kv/${TEST_KEY} → HTTP ${HTTP_STATUS}"

# GET — value must match
GOT="$(curl -sf "${BASE}/kv/${TEST_KEY}" 2>/dev/null || true)"
if [[ "${GOT}" != "${TEST_VAL}" ]]; then
    die "GET /kv/${TEST_KEY}: expected '${TEST_VAL}', got '${GOT}'"
fi
ok "GET /kv/${TEST_KEY} → value matches"

# DELETE
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE "${BASE}/kv/${TEST_KEY}")"
if [[ "${HTTP_STATUS}" != "200" && "${HTTP_STATUS}" != "204" && "${HTTP_STATUS}" != "202" ]]; then
    die "DELETE /kv/${TEST_KEY} returned HTTP ${HTTP_STATUS}"
fi
ok "DELETE /kv/${TEST_KEY} → HTTP ${HTTP_STATUS}"

# GET after DELETE — must be 404
HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/kv/${TEST_KEY}")"
if [[ "${HTTP_STATUS}" != "404" ]]; then
    die "GET /kv/${TEST_KEY} after DELETE: expected HTTP 404, got HTTP ${HTTP_STATUS}"
fi
ok "GET /kv/${TEST_KEY} after DELETE → HTTP 404 (correct)"

# ── Done ─────────────────────────────────────────────────────────────────────

printf '%s\n' '' "All smoke tests passed." ''
