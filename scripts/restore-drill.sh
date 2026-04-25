#!/usr/bin/env bash
# restore-drill.sh — end-to-end backup + restore verification drill.
#
# Proves that backup and restore work correctly by:
#   1. Writing known drill keys to the running app
#   2. Taking a backup
#   3. Overwriting the drill keys with dirty values (simulates data loss)
#   4. Running a full restore from the just-taken snapshot
#   5. Verifying the original drill key values are recovered
#
# The StatefulSet is scaled down and up as part of the restore step.
# This command is intentionally separate from make demo and make demo-full.
#
# Usage:
#   make restore-drill
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

LOCAL_PORT=18082
BASE="http://localhost:${LOCAL_PORT}"
PF_PID=""
DRILL_TS="$(date +%s)"

DRILL_KEYS=(drill-marker-a drill-marker-b drill-marker-c)
declare -A DRILL_VALS=(
    [drill-marker-a]="alpha-${DRILL_TS}"
    [drill-marker-b]="beta-${DRILL_TS}"
    [drill-marker-c]="gamma-${DRILL_TS}"
)
DIRTY_VAL="dirty-overwrite-${DRILL_TS}"

require kubectl
require curl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: restore-drill ==='

# ── Cleanup on exit ───────────────────────────────────────────────────────────

_cleanup() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
        PF_PID=""
    fi
}
trap _cleanup EXIT

# ── Port-forward helpers ───────────────────────────────────────────────────────

_start_portforward() {
    local app_pod
    app_pod="$(kubectl get pods -n "${NS_APP}" \
        -l "app.kubernetes.io/name=leveldb-app" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
        | head -1 || true)"
    if [[ -z "${app_pod}" ]]; then
        die "No app pod found. Is the StatefulSet running?"
    fi
    kubectl port-forward "pod/${app_pod}" "${LOCAL_PORT}:8080" \
        --namespace "${NS_APP}" &>/dev/null &
    PF_PID=$!
    local _
    for _ in $(seq 1 15); do
        if curl -sf "${BASE}/healthz" &>/dev/null; then
            ok "Port-forward ready on localhost:${LOCAL_PORT} (pod: ${app_pod})"
            return 0
        fi
        sleep 1
    done
    die "Port-forward did not become ready after 15s"
}

_stop_portforward() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
        PF_PID=""
    fi
}

# ── KV helpers ────────────────────────────────────────────────────────────────

_put_key() {
    local key="$1" val="$2"
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' \
        -X PUT "${BASE}/kv/${key}" \
        -H "Content-Type: text/plain" \
        --data-raw "${val}")"
    if [[ "${status}" != "200" && "${status}" != "201" && "${status}" != "204" ]]; then
        die "PUT /kv/${key} returned HTTP ${status}"
    fi
    ok "PUT /kv/${key} = '${val}'"
}

_get_key() {
    curl -sf "${BASE}/kv/$1" 2>/dev/null || true
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

section "Pre-flight"

if ! command -v k3d &>/dev/null || ! cluster_exists; then
    die "Cluster '${CLUSTER_NAME}' does not exist. Run: make bootstrap"
fi
if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "kubectl cannot reach the cluster. Check context: kubectl config current-context"
fi
if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    die "Namespace '${NS_APP}' not found. Run: make deploy"
fi
if ! kubectl get statefulset leveldb-app -n "${NS_APP}" &>/dev/null 2>&1; then
    die "StatefulSet 'leveldb-app' not found. Run: make deploy"
fi
if ! kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    die "CronJob '${BACKUP_CRONJOB_NAME}' not found. Run: make deploy"
fi
ok "Cluster, StatefulSet, and CronJob found"

# ── Step 1: write drill keys ──────────────────────────────────────────────────

section "Step 1 — write drill keys"

_start_portforward

for key in "${DRILL_KEYS[@]}"; do
    _put_key "${key}" "${DRILL_VALS[${key}]}"
done

for key in "${DRILL_KEYS[@]}"; do
    got="$(_get_key "${key}")"
    expected="${DRILL_VALS[${key}]}"
    if [[ "${got}" != "${expected}" ]]; then
        die "GET /kv/${key}: expected '${expected}', got '${got}'"
    fi
    ok "GET /kv/${key} = '${got}' (verified)"
done

_stop_portforward

# ── Step 2: backup ────────────────────────────────────────────────────────────

section "Step 2 — backup"

bash "${SCRIPT_DIR}/backup.sh"

# ── Step 3: overwrite drill keys with dirty values ────────────────────────────

section "Step 3 — overwrite drill keys (simulating data loss)"

_start_portforward

for key in "${DRILL_KEYS[@]}"; do
    _put_key "${key}" "${DIRTY_VAL}"
done

for key in "${DRILL_KEYS[@]}"; do
    got="$(_get_key "${key}")"
    if [[ "${got}" != "${DIRTY_VAL}" ]]; then
        die "Dirty write verification failed for /kv/${key}: got '${got}'"
    fi
    ok "GET /kv/${key} = '${got}' (dirty, pre-restore)"
done

_stop_portforward

# ── Step 4: restore ───────────────────────────────────────────────────────────

section "Step 4 — restore from snapshot"

bash "${SCRIPT_DIR}/restore.sh"

# ── Step 5: verify drill keys are recovered ───────────────────────────────────

section "Step 5 — verify drill keys after restore"

_start_portforward

PASS=1
for key in "${DRILL_KEYS[@]}"; do
    got="$(_get_key "${key}")"
    expected="${DRILL_VALS[${key}]}"
    if [[ "${got}" == "${expected}" ]]; then
        ok "GET /kv/${key} = '${got}' (matches pre-backup value)"
    else
        warn "MISMATCH /kv/${key}: expected '${expected}', got '${got}'"
        PASS=0
    fi
done

_stop_portforward

# ── Summary ───────────────────────────────────────────────────────────────────

if [[ "${PASS}" -eq 1 ]]; then
    printf '%s\n' \
        '' \
        '════════════════════════════════════════════════════════════' \
        ' Restore drill PASSED' \
        '════════════════════════════════════════════════════════════' \
        '' \
        '  Backup written, dirty overwrite applied, restore completed.' \
        '  All drill keys recovered to their pre-backup values.' \
        ''
else
    printf '%s\n' \
        '' \
        '════════════════════════════════════════════════════════════' \
        ' Restore drill FAILED' \
        '════════════════════════════════════════════════════════════' \
        '' \
        '  One or more drill keys did not match after restore.' \
        '  Check restore logs: make logs' \
        '' >&2
    exit 1
fi
