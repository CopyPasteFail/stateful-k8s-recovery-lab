#!/usr/bin/env bash
# backup-status.sh — show CronJob status and recent backup Job logs.
#
# Does not require restic on the host. All state is read from the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TAIL_LINES=80

require kubectl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: backup-status ==='

# ── Namespace guard ───────────────────────────────────────────────────────────

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    warn "Namespace '${NS_APP}' does not exist. Run: make deploy"
    printf '\n'
    exit 0
fi

# ── CronJob ───────────────────────────────────────────────────────────────────

section "CronJob (${BACKUP_CRONJOB_NAME})"

if ! kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    warn "CronJob '${BACKUP_CRONJOB_NAME}' not found. Run: make deploy"
    printf '\n'
    exit 0
fi

kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
    -o custom-columns=\
'NAME:.metadata.name,SCHEDULE:.spec.schedule,SUSPEND:.spec.suspend,ACTIVE:.status.active,LAST-SCHEDULE:.status.lastScheduleTime'

# ── Recent Jobs ───────────────────────────────────────────────────────────────

section "Recent backup Jobs (${NS_APP})"

JOB_LIST="$(kubectl get jobs -n "${NS_APP}" \
    -l "app.kubernetes.io/component=backup" \
    --sort-by='.metadata.creationTimestamp' \
    --no-headers 2>/dev/null | tail -10 || true)"

if [[ -z "${JOB_LIST}" ]]; then
    info "No backup Jobs found yet."
    info "Run: make backup  to trigger the first backup."
    printf '\n'
    exit 0
fi

printf '%s\n' "${JOB_LIST}"

# ── Latest Job logs ───────────────────────────────────────────────────────────

section "Latest backup Job logs"

LATEST_JOB="$(kubectl get jobs -n "${NS_APP}" \
    -l "app.kubernetes.io/component=backup" \
    --sort-by='.metadata.creationTimestamp' \
    --no-headers 2>/dev/null | tail -1 | awk '{print $1}' || true)"

if [[ -z "${LATEST_JOB}" ]]; then
    info "No Jobs to show logs for."
    printf '\n'
    exit 0
fi

info "Job: ${LATEST_JOB}"

LATEST_POD="$(kubectl get pods -n "${NS_APP}" \
    -l "job-name=${LATEST_JOB}" \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
    | head -1 || true)"

if [[ -n "${LATEST_POD}" ]]; then
    info "Pod: ${LATEST_POD}"
    kubectl logs -n "${NS_APP}" "${LATEST_POD}" \
        --tail="${TAIL_LINES}" 2>/dev/null || \
        warn "Could not retrieve logs from '${LATEST_POD}'"
else
    warn "No pod found for Job '${LATEST_JOB}' (pod may have been garbage-collected)."
fi

printf '\n'
