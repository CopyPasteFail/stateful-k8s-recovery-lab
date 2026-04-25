#!/usr/bin/env bash
# restore.sh — restore a Restic snapshot to the app PVC.
#
# Safe-hold on failure: the StatefulSet stays at 0 replicas and the CronJob
# stays suspended. An operator must explicitly recover (see printed instructions).
#
# Usage:
#   make restore                    restore the latest snapshot
#   make restore SNAPSHOT=latest    same as above
#   make restore SNAPSHOT=<id>      restore a specific snapshot ID
#   FORCE=1 make restore            skip the active-backup-job guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SNAPSHOT="${SNAPSHOT:-latest}"
FORCE="${FORCE:-0}"

STATEFULSET_NAME="leveldb-app"
RESTORE_JOB_PREFIX="leveldb-restore-manual"
RESTIC_IMAGE="restic/restic:0.17.3"
RESTIC_SECRET="leveldb-app-restic"
RESTIC_REPOSITORY="s3:http://minio.minio-system.svc.cluster.local:9000/restic"
PVC_NAME="data-leveldb-app-0"

WAIT_SCALE_DOWN=120   # seconds to wait for pod termination
WAIT_JOB=600          # seconds to wait for restore Job completion
WAIT_SCALE_UP=120     # seconds to wait for pod ready after scale-up

# ── Recovery instructions ─────────────────────────────────────────────────────
# Only printed if RESTORE_STARTED=1 (i.e., the system has been modified).

RESTORE_STARTED=0

_print_recovery() {
    printf '%s\n' \
        '' \
        '════════════════════════════════════════════════════════════' \
        ' RESTORE FAILED — system is in a safe holding state' \
        '════════════════════════════════════════════════════════════' \
        '' \
        "  StatefulSet '${STATEFULSET_NAME}': 0 replicas  (app stopped)" \
        "  CronJob '${BACKUP_CRONJOB_NAME}':  suspended   (no scheduled backups)" \
        '' \
        'Recovery commands:' \
        '' \
        "  # Inspect the restore Job logs:" \
        "  kubectl logs -n ${NS_APP} \\" \
        "    -l app.kubernetes.io/component=restore --tail=100" \
        '' \
        "  # Restart the app on existing PVC data (skip restore):" \
        "  kubectl scale statefulset/${STATEFULSET_NAME} --replicas=1 -n ${NS_APP}" \
        "  make resume-backups" \
        '' \
        "  # Retry with a specific snapshot:" \
        "  make restore SNAPSHOT=<snapshot-id>" \
        ''
}

_on_exit() {
    local CODE
    CODE=$?
    if [[ ${CODE} -ne 0 ]] && [[ ${RESTORE_STARTED} -eq 1 ]]; then
        _print_recovery
    fi
}
trap '_on_exit' EXIT

require kubectl

printf '%s\n' '' '=== stateful-k8s-recovery-lab: restore ===' \
    "  snapshot: ${SNAPSHOT}"

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
if ! kubectl get statefulset "${STATEFULSET_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    die "StatefulSet '${STATEFULSET_NAME}' not found. Run: make deploy"
fi
if ! kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" &>/dev/null 2>&1; then
    die "CronJob '${BACKUP_CRONJOB_NAME}' not found. Run: make deploy"
fi
ok "StatefulSet and CronJob found"

# ── Active backup guard ───────────────────────────────────────────────────────

section "Active backup guard"

ACTIVE_BACKUP="$(kubectl get jobs -n "${NS_APP}" \
    -l "app.kubernetes.io/component=backup" \
    --no-headers 2>/dev/null \
    | awk '$2 != "Complete" && $2 != "Failed" {print $1}' \
    | head -1 || true)"

if [[ -n "${ACTIVE_BACKUP}" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
        warn "Active backup Job '${ACTIVE_BACKUP}' is running. FORCE=1: proceeding anyway."
    else
        warn "Active backup Job '${ACTIVE_BACKUP}' is running."
        warn "Wait for it to complete, or run: FORCE=1 make restore"
        exit 1
    fi
else
    ok "No active backup Jobs"
fi

# ── Suspend backup CronJob ────────────────────────────────────────────────────
# Modify cluster state from here on → set RESTORE_STARTED so recovery
# instructions are shown if anything fails below.

section "Suspend backup CronJob"

SUSPENDED="$(kubectl get cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"

if [[ "${SUSPENDED}" == "true" ]]; then
    ok "CronJob '${BACKUP_CRONJOB_NAME}' already suspended"
else
    kubectl patch cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
        -p '{"spec":{"suspend":true}}' >/dev/null
    ok "CronJob '${BACKUP_CRONJOB_NAME}' suspended"
fi

RESTORE_STARTED=1   # recovery instructions shown on any error from here

# ── Scale StatefulSet to 0 ────────────────────────────────────────────────────

section "Scale down StatefulSet"

CURRENT_REPLICAS="$(kubectl get statefulset "${STATEFULSET_NAME}" -n "${NS_APP}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '0')"

if [[ "${CURRENT_REPLICAS}" == "0" ]]; then
    ok "StatefulSet '${STATEFULSET_NAME}' already at 0 replicas"
else
    info "Scaling '${STATEFULSET_NAME}' to 0 replicas ..."
    kubectl scale statefulset "${STATEFULSET_NAME}" --replicas=0 \
        -n "${NS_APP}" >/dev/null
fi

info "Waiting for app pod to terminate (timeout: ${WAIT_SCALE_DOWN}s) ..."
ELAPSED=0
while [[ ${ELAPSED} -lt ${WAIT_SCALE_DOWN} ]]; do
    # kubectl exits non-zero when the pod is gone; redirect all output.
    # Check the pod by name rather than the name label, which is shared
    # with backup/restore Job pods.
    if ! kubectl get pod "${STATEFULSET_NAME}-0" -n "${NS_APP}" \
            &>/dev/null 2>&1; then
        ok "App pod terminated"
        break
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done
if [[ ${ELAPSED} -ge ${WAIT_SCALE_DOWN} ]]; then
    die "Timed out waiting for pod termination after ${WAIT_SCALE_DOWN}s"
fi

# ── Create restore Job ────────────────────────────────────────────────────────

section "Creating restore Job"

JOB_NAME="${RESTORE_JOB_PREFIX}-$(date +%s)"
RESTORE_TS="$(date +%Y%m%d%H%M%S)"

info "Job:      ${JOB_NAME}"
info "Snapshot: ${SNAPSHOT}"

# The heredoc is unquoted so bash expands outer variables (JOB_NAME, NS_APP,
# SNAPSHOT, RESTORE_TS, RESTIC_IMAGE, RESTIC_SECRET, RESTIC_REPOSITORY,
# PVC_NAME, WAIT_JOB). Variables meant for the container shell are escaped
# with \$ so they reach the container unexpanded and are resolved at runtime.
kubectl create -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS_APP}
  labels:
    app.kubernetes.io/name: leveldb-app
    app.kubernetes.io/instance: leveldb-app
    app.kubernetes.io/component: restore
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${WAIT_JOB}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: leveldb-app
        app.kubernetes.io/component: restore
    spec:
      restartPolicy: Never
      serviceAccountName: leveldb-app
      # Run as the same UID/GID as the app so the container can read and write
      # PVC files. fsGroup ensures the mounted volume root is group-writable.
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true
      containers:
        - name: restic
          image: ${RESTIC_IMAGE}
          # /bin/sh is BusyBox ash in the restic/restic image (Alpine-based).
          # pipefail is not available in BusyBox sh; use set -eu only.
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              printf '%s\n' '' '=== leveldb-app restore ==='
              printf 'repository : %s\n' "\${RESTIC_REPOSITORY}"
              printf 'snapshot   : %s\n' "\${SNAPSHOT_ID}"

              WORK_DIR="/restore-target/.restore-work"

              printf '%s\n' '' '--- available snapshots ---'
              restic snapshots --latest 10

              printf '%s\n' '' '--- restoring snapshot into work directory ---'
              if [ -d "\${WORK_DIR}" ]; then
                printf '[info] removing previous work directory\n'
                rm -rf "\${WORK_DIR}"
              fi

              restic restore "\${SNAPSHOT_ID}" --target "\${WORK_DIR}"

              RESTORED_PATH="\${WORK_DIR}/backup-source/leveldb"
              if [ ! -d "\${RESTORED_PATH}" ]; then
                printf 'ERROR: expected path not found after restore: %s\n' "\${RESTORED_PATH}" >&2
                printf 'Work directory contents:\n' >&2
                find "\${WORK_DIR}" -maxdepth 4 2>/dev/null >&2 || true
                exit 1
              fi
              printf '[ok]   restored data verified at: %s\n' "\${RESTORED_PATH}"

              printf '%s\n' '' '--- swapping data directory ---'
              if [ -d "/restore-target/leveldb" ]; then
                PREV="/restore-target/leveldb.pre-restore-${RESTORE_TS}"
                printf '[info] moving existing data aside: %s\n' "\${PREV}"
                mv "/restore-target/leveldb" "\${PREV}"
                printf '[ok]   previous data preserved at: %s\n' "\${PREV}"
              fi

              mv "\${RESTORED_PATH}" "/restore-target/leveldb"
              printf '[ok]   restored data placed at: /restore-target/leveldb\n'

              rm -rf "\${WORK_DIR}"
              printf '[ok]   work directory removed\n'

              printf '%s\n' '' '--- snapshot list ---'
              restic snapshots --latest 5

              printf '%s\n' '' '=== restore job done ==='
          env:
            - name: SNAPSHOT_ID
              value: "${SNAPSHOT}"
            - name: RESTIC_REPOSITORY
              value: "${RESTIC_REPOSITORY}"
            - name: RESTIC_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${RESTIC_SECRET}
                  key: restic-password
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: ${RESTIC_SECRET}
                  key: aws-access-key-id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: ${RESTIC_SECRET}
                  key: aws-secret-access-key
            - name: RESTIC_CACHE_DIR
              value: /tmp/restic-cache
          volumeMounts:
            - name: restore-target
              mountPath: /restore-target
      volumes:
        - name: restore-target
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

ok "Job '${JOB_NAME}' created"

# ── Wait for restore Job ──────────────────────────────────────────────────────

section "Waiting for restore Job"

info "Timeout: ${WAIT_JOB}s."

ELAPSED=0
JOB_POD=""

while [[ ${ELAPSED} -lt ${WAIT_JOB} ]]; do
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
        ok "Restore Job completed"
        break
    fi

    if [[ "${FAILED}" == "True" ]]; then
        section "Restore Job logs (on failure)"
        if [[ -n "${JOB_POD}" ]]; then
            kubectl logs -n "${NS_APP}" "${JOB_POD}" 2>/dev/null || true
        fi
        die "Restore Job '${JOB_NAME}' failed. See logs above."
    fi

    if [[ $(( ELAPSED % 30 )) -eq 0 ]] && [[ ${ELAPSED} -gt 0 ]]; then
        info "Still waiting... ${ELAPSED}s elapsed"
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done

if [[ ${ELAPSED} -ge ${WAIT_JOB} ]]; then
    die "Timed out waiting for restore Job '${JOB_NAME}' after ${WAIT_JOB}s"
fi

# ── Print restore Job logs ────────────────────────────────────────────────────

section "Restore Job logs"

if [[ -z "${JOB_POD}" ]]; then
    JOB_POD="$(kubectl get pods -n "${NS_APP}" \
        -l "job-name=${JOB_NAME}" \
        --no-headers -o custom-columns=':metadata.name' 2>/dev/null \
        | head -1 || true)"
fi

if [[ -n "${JOB_POD}" ]]; then
    kubectl logs -n "${NS_APP}" "${JOB_POD}" 2>/dev/null || \
        warn "Could not retrieve logs from '${JOB_POD}'"
fi

# ── Scale up ──────────────────────────────────────────────────────────────────

section "Scale up StatefulSet"

info "Scaling '${STATEFULSET_NAME}' to 1 replica ..."
kubectl scale statefulset "${STATEFULSET_NAME}" --replicas=1 \
    -n "${NS_APP}" >/dev/null

info "Waiting for rollout (timeout: ${WAIT_SCALE_UP}s) ..."
kubectl rollout status "statefulset/${STATEFULSET_NAME}" \
    -n "${NS_APP}" --timeout="${WAIT_SCALE_UP}s"
ok "StatefulSet '${STATEFULSET_NAME}' rolled out"

# ── Readiness check ───────────────────────────────────────────────────────────

section "Readiness check"

APP_POD="${STATEFULSET_NAME}-0"

if [[ -n "${APP_POD}" ]]; then
    info "Waiting for pod '${APP_POD}' to become Ready ..."
    ELAPSED=0
    while [[ ${ELAPSED} -lt 60 ]]; do
        READY="$(kubectl get pod "${APP_POD}" -n "${NS_APP}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || true)"
        if [[ "${READY}" == "True" ]]; then
            ok "Pod '${APP_POD}' is Ready"
            break
        fi
        sleep 3
        ELAPSED=$(( ELAPSED + 3 ))
    done
    if [[ ${ELAPSED} -ge 60 ]]; then
        warn "Pod '${APP_POD}' did not become Ready within 60s — check: make logs"
    fi
else
    warn "No app pod found after scale-up"
fi

# ── Resume backup CronJob ─────────────────────────────────────────────────────
# Explicit success path: resume is never called automatically on failure.

section "Resume backup CronJob"

kubectl patch cronjob "${BACKUP_CRONJOB_NAME}" -n "${NS_APP}" \
    -p '{"spec":{"suspend":false}}' >/dev/null
ok "CronJob '${BACKUP_CRONJOB_NAME}' resumed"

CRON_SCHEDULE="$(kubectl get cronjob "${BACKUP_CRONJOB_NAME}" \
    -n "${NS_APP}" -o jsonpath='{.spec.schedule}' 2>/dev/null || echo 'unknown')"

printf '%s\n' \
    '' \
    '════════════════════════════════════════════════════════════' \
    ' Restore complete' \
    '════════════════════════════════════════════════════════════' \
    '' \
    "  Snapshot:  ${SNAPSHOT}" \
    "  Job:       ${JOB_NAME}" \
    "  App pod:   ${APP_POD:-unknown}" \
    "  Backups:   resumed  (schedule: ${CRON_SCHEDULE})" \
    ''
