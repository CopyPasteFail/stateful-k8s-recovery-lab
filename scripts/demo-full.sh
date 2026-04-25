#!/usr/bin/env bash
# demo-full.sh — end-to-end demo of the complete platform including observability.
#
# Runs the full happy path in order:
#   check-prereqs      → bootstrap         → deploy-minio
#   deploy-observability → deploy           → seed-data
#   backup             → smoke-test        → backup-status
#   status
#
# Expect ~10-15 minutes on first run due to image pulls for Prometheus,
# Grafana, Loki, and Promtail. Subsequent runs are faster (images cached).
#
# Restore is intentionally excluded: it is a disruptive recovery operation
# that does not belong in an automated demo. To validate the restore path:
#   make restore
#
# Usage:
#   make demo-full
#
# Idempotent: safe to run on an already-bootstrapped cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MAKE="${MAKE:-make}"

# ── helpers ───────────────────────────────────────────────────────────────────

_banner() {
    local step="$1" total="$2" target="$3"
    printf '\n%s\n' \
        '════════════════════════════════════════════════════════════' \
        "  STEP ${step}/${total} — make ${target}" \
        '════════════════════════════════════════════════════════════'
    printf '\n'
}

TOTAL=10

# ── steps ─────────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    '╔══════════════════════════════════════════════════════════════╗' \
    '║         stateful-k8s-recovery-lab  —  demo-full             ║' \
    '╚══════════════════════════════════════════════════════════════╝' \
    '' \
    '  Full platform: app + MinIO + backup + Prometheus/Grafana/Loki' \
    '  First run may take 10-15 min due to image pulls.' \
    ''

_banner 1 "${TOTAL}" check-prereqs
"${MAKE}" -C "${REPO_ROOT}" check-prereqs

_banner 2 "${TOTAL}" bootstrap
"${MAKE}" -C "${REPO_ROOT}" bootstrap

_banner 3 "${TOTAL}" deploy-minio
"${MAKE}" -C "${REPO_ROOT}" deploy-minio

_banner 4 "${TOTAL}" deploy-observability
"${MAKE}" -C "${REPO_ROOT}" deploy-observability

_banner 5 "${TOTAL}" "deploy (MONITORING=1)"
MONITORING=1 "${MAKE}" -C "${REPO_ROOT}" deploy

_banner 6 "${TOTAL}" seed-data
"${MAKE}" -C "${REPO_ROOT}" seed-data

_banner 7 "${TOTAL}" backup
"${MAKE}" -C "${REPO_ROOT}" backup

_banner 8 "${TOTAL}" smoke-test
"${MAKE}" -C "${REPO_ROOT}" smoke-test

_banner 9 "${TOTAL}" backup-status
"${MAKE}" -C "${REPO_ROOT}" backup-status

_banner 10 "${TOTAL}" status
"${MAKE}" -C "${REPO_ROOT}" status

# ── summary ───────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    '╔══════════════════════════════════════════════════════════════╗' \
    '║  Demo complete — all steps passed                           ║' \
    '╚══════════════════════════════════════════════════════════════╝' \
    '' \
    '  Access the app:' \
    '    make port-forward TARGET=app            # http://localhost:18081' \
    '' \
    '  Access observability:' \
    '    make port-forward TARGET=grafana        # http://localhost:3000' \
    '    make port-forward TARGET=prometheus     # http://localhost:9090' \
    '    make port-forward TARGET=alertmanager   # http://localhost:9093' \
    '' \
    '  Access MinIO:' \
    '    make port-forward TARGET=minio-console  # http://localhost:9001' \
    '' \
    '  Validate the restore path (disruptive — scales app to 0):' \
    '    make restore' \
    ''
