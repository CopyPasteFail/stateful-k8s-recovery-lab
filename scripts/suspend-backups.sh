#!/usr/bin/env bash
# suspend-backups.sh — set spec.suspend=true on the backup CronJob.
#                      Any Job already running continues to completion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require kubectl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: suspend-backups ==='

section "Pre-flight"

if ! kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    die "Namespace '${NS_APP}' does not exist. Run: make deploy"
fi

if ! kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    die "CronJob '${BACKUP_CRONJOB_NAME}' not found in '${NS_APP}'. Run: make deploy"
fi

SUSPENDED="$(kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"

if [[ "${SUSPENDED}" == "true" ]]; then
    ok "CronJob '${BACKUP_CRONJOB_NAME}' is already suspended — nothing to do."
    printf '\n'
    exit 0
fi

section "Suspending"

kubectl patch cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
    -p '{"spec":{"suspend":true}}' >/dev/null
ok "CronJob '${BACKUP_CRONJOB_NAME}' suspended."
info "Scheduled Jobs will not fire until you run: make resume-backups"
info "Any Job currently running will complete normally."

printf '\n'
