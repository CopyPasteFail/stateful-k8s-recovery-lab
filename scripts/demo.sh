#!/usr/bin/env bash
# demo.sh — end-to-end demo of the core stateful-app workflow.
#
# Runs the main happy path in order:
#   check-prereqs  → bootstrap  → deploy-minio  → deploy
#   seed-data      → backup     → smoke-test
#   backup-status  → status
#
# Observability (Prometheus/Grafana/Loki) is NOT included here to keep
# runtime reasonable (~3-5 min vs ~10-15 min with image pulls).
# Run 'make demo-full' to include the full observability stack.
#
# Restore is intentionally excluded: it is a disruptive recovery operation
# (scales the app down, overwrites PVC data) that does not belong in an
# automated demo. To validate the restore path run:
#   make backup       # ensure a snapshot exists
#   make restore      # guided restore: scale-down → restore → scale-up
#
# Usage:
#   make demo
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

TOTAL=9

# ── steps ─────────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    '╔══════════════════════════════════════════════════════════════╗' \
    '║         stateful-k8s-recovery-lab  —  demo                  ║' \
    '╚══════════════════════════════════════════════════════════════╝' \
    '' \
    '  Core workflow: app + MinIO + backup (no observability)' \
    '  Run "make demo-full" to include Prometheus / Grafana / Loki.' \
    ''

_banner 1 "${TOTAL}" check-prereqs
"${MAKE}" -C "${REPO_ROOT}" check-prereqs

_banner 2 "${TOTAL}" bootstrap
"${MAKE}" -C "${REPO_ROOT}" bootstrap

_banner 3 "${TOTAL}" deploy-minio
"${MAKE}" -C "${REPO_ROOT}" deploy-minio

_banner 4 "${TOTAL}" deploy
"${MAKE}" -C "${REPO_ROOT}" deploy

_banner 5 "${TOTAL}" seed-data
"${MAKE}" -C "${REPO_ROOT}" seed-data

_banner 6 "${TOTAL}" backup
"${MAKE}" -C "${REPO_ROOT}" backup

_banner 7 "${TOTAL}" smoke-test
"${MAKE}" -C "${REPO_ROOT}" smoke-test

_banner 8 "${TOTAL}" backup-status
"${MAKE}" -C "${REPO_ROOT}" backup-status

_banner 9 "${TOTAL}" status
"${MAKE}" -C "${REPO_ROOT}" status

# ── summary ───────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    '╔══════════════════════════════════════════════════════════════╗' \
    '║  Demo complete — all steps passed                           ║' \
    '╚══════════════════════════════════════════════════════════════╝' \
    '' \
    '  Access the app:' \
    '    make port-forward TARGET=app       # http://localhost:8080' \
    '' \
    '  Access MinIO:' \
    '    make port-forward TARGET=minio-console  # http://localhost:9001' \
    '' \
    '  Validate the restore path (disruptive — scales app to 0):' \
    '    make restore' \
    '' \
    '  Deploy observability and see the full platform:' \
    '    make demo-full' \
    ''
