#!/usr/bin/env bash
# deploy.sh — build the app image, load it into k3d, and deploy via Helm.
# Safe to rerun: docker build and helm upgrade --install are both idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

HELM_RELEASE="leveldb-app"
HELM_CHART="${REPO_ROOT}/charts/leveldb-app"
IMAGE="stateful-k8s-recovery-lab/leveldb-app:local"

# MONITORING=1 enables ServiceMonitor, PrometheusRule, and Grafana dashboard.
# Requires kube-prometheus-stack to be installed first (make deploy-observability).
# Default: disabled so the chart works on a fresh cluster without CRDs.
MONITORING="${MONITORING:-0}"

printf '%s\n' '' '=== stateful-k8s-recovery-lab: deploy ==='

section "Prerequisites"
require docker
require k3d
require kubectl
require helm
ok "Prerequisites satisfied"

section "Cluster"
if ! cluster_exists; then
    die "Cluster '${CLUSTER_NAME}' does not exist. Run: make bootstrap"
fi
if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "kubectl cannot reach the cluster. Check context: kubectl config current-context"
fi
ok "Cluster '${CLUSTER_NAME}' exists and is reachable"

section "Image"
info "Building ${IMAGE} ..."
docker build -t "${IMAGE}" "${REPO_ROOT}/app"
ok "Image built: ${IMAGE}"

info "Loading image into k3d cluster '${CLUSTER_NAME}' ..."
k3d image import "${IMAGE}" --cluster "${CLUSTER_NAME}"
ok "Image loaded"

section "Namespace"
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    ok "Namespace '${NS_APP}' already exists"
else
    kubectl create namespace "${NS_APP}" >/dev/null
    ok "Namespace '${NS_APP}' created"
fi

section "Helm"

# Build optional monitoring flags
MONITORING_FLAGS=()
if [[ "${MONITORING}" == "1" ]]; then
    info "MONITORING=1 — checking for monitoring.coreos.com CRDs ..."
    if ! kubectl get crd servicemonitors.monitoring.coreos.com \
            &>/dev/null 2>&1; then
        die "ServiceMonitor CRD not found. Run: make deploy-observability"
    fi
    MONITORING_FLAGS=(
        --set monitoring.enabled=true
        --set monitoring.serviceMonitor.enabled=true
        --set monitoring.prometheusRule.enabled=true
        --set monitoring.grafanaDashboard.enabled=true
    )
    ok "Monitoring CRDs present — monitoring resources will be created"
fi

info "Running: helm upgrade --install ${HELM_RELEASE} ${HELM_CHART} ..."
helm upgrade --install "${HELM_RELEASE}" "${HELM_CHART}" \
    --namespace "${NS_APP}" \
    --wait \
    --timeout 5m \
    "${MONITORING_FLAGS[@]+"${MONITORING_FLAGS[@]}"}"
ok "Helm release '${HELM_RELEASE}' deployed"

section "Rollout"
info "Waiting for StatefulSet rollout ..."
kubectl rollout status statefulset/"${HELM_RELEASE}" \
    --namespace "${NS_APP}" \
    --timeout=2m
ok "StatefulSet '${HELM_RELEASE}' is ready"

printf '%s\n' \
    '' \
    "App deployed in namespace '${NS_APP}'." \
    '' \
    'Next steps:' \
    '  make status' \
    '  make port-forward TARGET=app' \
    '  make smoke-test' \
    ''
