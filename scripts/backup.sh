#!/usr/bin/env bash
# backup.sh — trigger a one-off backup Job from the backup CronJob spec.
#
# Usage:
#   make backup           create Job, wait, print logs
#   FORCE=1 make backup   proceed even if a backup Job is already active
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FORCE="${FORCE:-0}"
WAIT_TIMEOUT=3600   # max seconds to wait for Job completion (1 hour)

require kubectl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: backup ==='

# ── Pre-flight ────────────────────────────────────────────────────────────────

section "Pre-flight"

if ! command -v k3d &>/dev/null || ! cluster_exists; then
    die "Cluster '${CLUSTER_NAME}' does not exist. Run: make bootstrap"
fi

if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "kubectl cannot reach the cluster. Check context: kubectl config current-context"
fi
ok "Cluster is reachable"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    die "Namespace '${NS_APP}' not found. Run: make deploy"
fi

if ! kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    die "CronJob '${BACKUP_CRONJOB_NAME}' not found in '${NS_APP}'. Run: make deploy"
fi
ok "CronJob '${BACKUP_CRONJOB_NAME}' found"

# ── Active job guard ──────────────────────────────────────────────────────────

section "Active jobs"

ACTIVE_JOB="$(kubectl get jobs -n "${NS_APP}" \
    -l "app.kubernetes.io/component=backup" \
    --no-headers 2>/dev/null \
    | awk '$2 != "Complete" && $2 != "Failed" {print $1}' \
    | head -1 || true)"

if [[ -n "${ACTIVE_JOB}" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
        warn "Active backup Job '${ACTIVE_JOB}' is running. FORCE=1: proceeding anyway."
    else
        warn "Active backup Job '${ACTIVE_JOB}' is already running."
        warn "Wait for it to finish or run: FORCE=1 make backup"
        printf '\n'
        exit 1
    fi
else
    ok "No active backup Jobs"
fi

# ── Create Job ────────────────────────────────────────────────────────────────

section "Creating Job"

JOB_NAME="${BACKUP_CRONJOB_NAME}-manual-$(date +%s)"
info "Creating Job '${JOB_NAME}' from CronJob '${BACKUP_CRONJOB_NAME}' ..."
kubectl create job "${JOB_NAME}" \
    --from="cronjob/${BACKUP_CRONJOB_NAME}" \
    -n "${NS_APP}" >/dev/null
ok "Job '${JOB_NAME}' created"

# ── Wait for completion ───────────────────────────────────────────────────────

section "Waiting for completion"

info "Timeout: ${WAIT_TIMEOUT}s. Press Ctrl-C to stop waiting (Job continues in cluster)."

ELAPSED=0
INTERVAL=5
JOB_POD=""

while [[ ${ELAPSED} -lt ${WAIT_TIMEOUT} ]]; do
    # Resolve pod name lazily — it appears a moment after Job creation.
    if [[ -z "${JOB_POD}" ]]; then
        JOB_POD="$(kubectl get pods -n "${NS_APP}" \
            -l "job-name=${JOB_NAME}" \
            --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
            | head -1 || true)"
    fi

    COMPLETE="$(kubectl get job "${JOB_NAME}" -n "${NS_APP}" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' \
        2>/dev/null || true)"
    FAILED="$(kubectl get job "${JOB_NAME}" -n "${NS_APP}" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' \
        2>/dev/null || true)"

    if [[ "${COMPLETE}" == "True" ]]; then
        ok "Job '${JOB_NAME}' completed successfully"
        break
    fi

    if [[ "${FAILED}" == "True" ]]; then
        printf '\n'
        section "Job logs (on failure)"
        if [[ -n "${JOB_POD}" ]]; then
            kubectl logs -n "${NS_APP}" "${JOB_POD}" 2>/dev/null || true
        fi
        die "Backup Job '${JOB_NAME}' failed. See logs above."
    fi

    if [[ $(( ELAPSED % 30 )) -eq 0 ]] && [[ ${ELAPSED} -gt 0 ]]; then
        info "Still waiting... ${ELAPSED}s elapsed"
    fi

    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))
done

if [[ ${ELAPSED} -ge ${WAIT_TIMEOUT} ]]; then
    die "Timed out waiting for backup Job '${JOB_NAME}' after ${WAIT_TIMEOUT}s"
fi

# ── Print logs ────────────────────────────────────────────────────────────────

section "Job logs"

# Refresh pod name in case it wasn't found earlier.
if [[ -z "${JOB_POD}" ]]; then
    JOB_POD="$(kubectl get pods -n "${NS_APP}" \
        -l "job-name=${JOB_NAME}" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
        | head -1 || true)"
fi

if [[ -n "${JOB_POD}" ]]; then
    kubectl logs -n "${NS_APP}" "${JOB_POD}" 2>/dev/null || \
        warn "Could not retrieve logs from '${JOB_POD}'"
else
    warn "No pod found for Job '${JOB_NAME}'"
fi

printf '%s\n' '' "Backup complete: ${JOB_NAME}" ''
