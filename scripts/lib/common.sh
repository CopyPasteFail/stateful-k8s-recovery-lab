#!/usr/bin/env bash
# common.sh — shared constants and helper functions.
# Source this file; do not execute it directly.
# Callers must set SCRIPT_DIR before sourcing.

# ── Cluster identity ──────────────────────────────────────────────────────────
# Must match metadata.name in k3d/cluster.yaml
CLUSTER_NAME="stateful-recovery"

# Path to the k3d config file, resolved from the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # used by scripts that source this file
K3D_CONFIG="${REPO_ROOT}/k3d/cluster.yaml"

# ── Resource names ────────────────────────────────────────────────────────────
# Must match charts/leveldb-app/templates/backup-cronjob.yaml
# (rendered from {{ include "leveldb-app.fullname" . }}-backup)
# shellcheck disable=SC2034  # used by scripts that source this file
BACKUP_CRONJOB_NAME="leveldb-app-backup"

# ── Namespace names ───────────────────────────────────────────────────────────
NS_APP="leveldb-system"
NS_MINIO="minio-system"
NS_OBSERVABILITY="observability"

# Ordered list used for iteration (bootstrap, status, etc.)
# shellcheck disable=SC2034  # used by scripts that source this file
NAMESPACES=("${NS_APP}" "${NS_MINIO}" "${NS_OBSERVABILITY}")

# ── Output helpers ────────────────────────────────────────────────────────────
ok()      { printf '  [ok]    %s\n' "$*"; }
info()    { printf '  [info]  %s\n' "$*"; }
warn()    { printf '  [warn]  %s\n' "$*"; }
# die prints to stderr and exits non-zero; callers do not need to exit after die()
die()     { printf '\nERROR: %s\n\n' "$*" >&2; exit 1; }

# section <title> — print a blank line then a section header.
# Uses printf '%s\n' so the format string never starts with '-',
# avoiding printf option-parsing on format strings that start with dashes.
section() { printf '%s\n' '' "--- $* ---"; }

# ── Prerequisite helpers ──────────────────────────────────────────────────────

# require <command> — exit with a helpful message if the command is not found
require() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "'${cmd}' is required but not found. Run: make check-prereqs"
    fi
}

# ── Cluster helpers ───────────────────────────────────────────────────────────

# cluster_exists — returns 0 if the named k3d cluster is present, 1 otherwise.
# Suppresses all output so it is safe to use in conditionals.
cluster_exists() {
    k3d cluster list 2>/dev/null \
        | awk 'NR>1 {print $1}' \
        | grep -qx "${CLUSTER_NAME}"
}
