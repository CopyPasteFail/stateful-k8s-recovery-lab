#!/usr/bin/env bash
# destroy.sh -- delete the local k3d cluster and all its data.
# Set FORCE=1 to skip the confirmation prompt (useful in scripted teardown).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

printf '%s\n' '' "=== stateful-k8s-recovery-lab: destroy cluster '${CLUSTER_NAME}' ==="

require k3d

if ! cluster_exists; then
    info "Cluster '${CLUSTER_NAME}' does not exist. Nothing to do."
    exit 0
fi

if [[ "${FORCE:-0}" != "1" ]]; then
    printf '%s\n' \
        '' \
        "This will permanently delete the k3d cluster '${CLUSTER_NAME}'." \
        'All cluster resources will be removed, including:' \
        '  - All namespaces and their workloads' \
        '  - All PersistentVolumes and PersistentVolumeClaims' \
        '  - In-cluster MinIO data (if MinIO has been deployed)' \
        '' \
        'Data backed up to external storage is not affected.' \
        ''
    printf 'Type the cluster name to confirm: '
    read -r answer
    if [[ "${answer}" != "${CLUSTER_NAME}" ]]; then
        printf 'Input did not match "%s". Aborting.\n\n' "${CLUSTER_NAME}"
        exit 1
    fi
fi

printf '\nDeleting cluster "%s" ...\n' "${CLUSTER_NAME}"
k3d cluster delete "${CLUSTER_NAME}"

printf '%s\n' \
    '' \
    "Cluster '${CLUSTER_NAME}' has been deleted." \
    'All local cluster data has been removed.' \
    'External resources (cloud storage, IAM, DNS) are not affected.' \
    '' \
    'To recreate: make bootstrap' \
    ''
