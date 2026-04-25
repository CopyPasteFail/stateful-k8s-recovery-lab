#!/usr/bin/env bash
# logs.sh — tail logs from the app pod, MinIO verification job, and recent
#           backup Jobs.
#
# Usage (via make):
#   make logs              tail last 50 lines from each source
#   FOLLOW=1 make logs     stream live app logs (Ctrl-C to stop)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

FOLLOW="${FOLLOW:-0}"
TAIL_LINES=50

require kubectl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: logs ==='

# ── App pod ───────────────────────────────────────────────────────────────────

section "App logs (${NS_APP})"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    warn "Namespace '${NS_APP}' does not exist. Run: make deploy"
else
    APP_POD="$(kubectl get pods -n "${NS_APP}" \
        -l "app.kubernetes.io/name=leveldb-app" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)"

    if [[ -z "${APP_POD}" ]]; then
        warn "No app pod found in '${NS_APP}'. Run: make deploy"
    else
        info "Pod: ${APP_POD}"
        if [[ "${FOLLOW}" == "1" ]]; then
            info "Following logs (Ctrl-C to stop) ..."
            kubectl logs -n "${NS_APP}" "${APP_POD}" --follow
        else
            kubectl logs -n "${NS_APP}" "${APP_POD}" \
                --tail="${TAIL_LINES}" 2>/dev/null || \
                warn "Could not retrieve logs from '${APP_POD}'"
        fi
    fi
fi

# ── Most recent backup Job ────────────────────────────────────────────────────

section "Recent backup Job logs (${NS_APP})"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    info "Namespace '${NS_APP}' not present — skipping."
else
    LATEST_JOB="$(kubectl get jobs -n "${NS_APP}" \
        -l "app.kubernetes.io/component=backup" \
        --sort-by='.metadata.creationTimestamp' \
        --no-headers 2>/dev/null | tail -1 | awk '{print $1}' || true)"

    if [[ -z "${LATEST_JOB}" ]]; then
        info "No backup Jobs found. Run: make backup"
    else
        info "Job: ${LATEST_JOB}"
        BACKUP_POD="$(kubectl get pods -n "${NS_APP}" \
            -l "job-name=${LATEST_JOB}" \
            --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
            | head -1 || true)"
        if [[ -n "${BACKUP_POD}" ]]; then
            info "Pod: ${BACKUP_POD}"
            kubectl logs -n "${NS_APP}" "${BACKUP_POD}" \
                --tail="${TAIL_LINES}" 2>/dev/null || \
                warn "Could not retrieve logs from '${BACKUP_POD}'"
        else
            info "No pod found for '${LATEST_JOB}' (may have been garbage-collected)."
        fi
    fi
fi

# ── Most recent restore Job ───────────────────────────────────────────────────

section "Recent restore Job logs (${NS_APP})"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    info "Namespace '${NS_APP}' not present — skipping."
else
    LATEST_RESTORE_JOB="$(kubectl get jobs -n "${NS_APP}" \
        -l "app.kubernetes.io/component=restore" \
        --sort-by='.metadata.creationTimestamp' \
        --no-headers 2>/dev/null | tail -1 | awk '{print $1}' || true)"

    if [[ -z "${LATEST_RESTORE_JOB}" ]]; then
        info "No restore Jobs found."
    else
        info "Job: ${LATEST_RESTORE_JOB}"
        RESTORE_POD="$(kubectl get pods -n "${NS_APP}" \
            -l "job-name=${LATEST_RESTORE_JOB}" \
            --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
            | head -1 || true)"
        if [[ -n "${RESTORE_POD}" ]]; then
            info "Pod: ${RESTORE_POD}"
            kubectl logs -n "${NS_APP}" "${RESTORE_POD}" \
                --tail="${TAIL_LINES}" 2>/dev/null || \
                warn "Could not retrieve logs from '${RESTORE_POD}'"
        else
            info "No pod found for '${LATEST_RESTORE_JOB}' (may have been garbage-collected)."
        fi
    fi
fi

# ── MinIO bucket-verification job ────────────────────────────────────────────

section "MinIO bucket-verification job (${NS_MINIO})"

if ! kubectl get namespace "${NS_MINIO}" &>/dev/null 2>&1; then
    info "Namespace '${NS_MINIO}' not present — skipping."
elif kubectl get job minio-ensure-restic-bucket -n "${NS_MINIO}" &>/dev/null 2>&1; then
    JOB_POD="$(kubectl get pods -n "${NS_MINIO}" \
        -l "job-name=minio-ensure-restic-bucket" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || true)"
    if [[ -n "${JOB_POD}" ]]; then
        info "Job pod: ${JOB_POD}"
        kubectl logs -n "${NS_MINIO}" "${JOB_POD}" \
            --tail="${TAIL_LINES}" 2>/dev/null || \
            warn "Could not retrieve job logs"
    else
        info "Job exists but no pod found (may have been garbage-collected)."
    fi
else
    info "Job 'minio-ensure-restic-bucket' not present — skipping."
fi

printf '\n'
