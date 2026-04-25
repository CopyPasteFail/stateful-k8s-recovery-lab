#!/usr/bin/env bash
# bootstrap.sh -- create the k3d cluster and set up namespaces.
# Safe to rerun: skips steps that are already complete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

printf '%s\n' '' '=== stateful-k8s-recovery-lab: bootstrap ==='

section "Prerequisites"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script requires Linux (detected: $(uname -s)). Use WSL2 on Windows."
fi

require docker
require k3d
require kubectl
require helm

if ! docker info &>/dev/null 2>&1; then
    die "Docker daemon is not reachable without sudo. Run: make install-docker, then log out and back in or run: newgrp docker"
fi

ok "Prerequisites satisfied"

section "k3d cluster"

if cluster_exists; then
    ok "Cluster '${CLUSTER_NAME}' already exists -- skipping creation"
else
    info "Creating cluster '${CLUSTER_NAME}' from ${K3D_CONFIG} ..."
    k3d cluster create --config "${K3D_CONFIG}"
    ok "Cluster '${CLUSTER_NAME}' created"
fi

# Set kubectl context to this cluster (idempotent)
kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
ok "kubectl context: k3d-${CLUSTER_NAME}"

section "Nodes"

info "Waiting for nodes to be Ready (timeout: 60s) ..."
kubectl wait nodes --all --for=condition=Ready --timeout=60s >/dev/null
kubectl get nodes
ok "All nodes Ready"

section "Namespaces"

for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
        ok "Namespace '${ns}' already exists"
    else
        kubectl create namespace "${ns}" >/dev/null
        ok "Namespace '${ns}' created"
    fi
done

section "Cluster info"

k3d cluster list
printf '\n'

printf '%s\n' \
    'Bootstrap complete.' \
    '' \
    'Next steps:' \
    '  make status        -- show cluster and namespace state' \
    '  make deploy-minio  -- deploy MinIO backup backend' \
    '  make deploy        -- deploy the leveldb-app StatefulSet' \
    ''
