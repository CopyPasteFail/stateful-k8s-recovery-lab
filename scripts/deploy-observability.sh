#!/usr/bin/env bash
# deploy-observability.sh — deploy the observability stack into the cluster.
#
# Installs (or upgrades) three Helm releases into the 'observability' namespace:
#   kube-prometheus-stack  — Prometheus, Grafana, Alertmanager, kube-state-metrics
#   loki                   — Log aggregation (SingleBinary mode, filesystem storage)
#   promtail               — Log shipper DaemonSet (tails pod logs → Loki)
#
# Usage:
#   make deploy-observability
#
# Idempotent: safe to run on an already-deployed stack (helm upgrade --install).
# After the stack is up, access it with:
#   make port-forward TARGET=grafana
#   make port-forward TARGET=prometheus
#   make port-forward TARGET=alertmanager
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Helm release names
RELEASE_PROM_STACK="kube-prometheus-stack"
RELEASE_LOKI="loki"
RELEASE_PROMTAIL="promtail"

# Helm chart references
CHART_PROM_STACK="prometheus-community/kube-prometheus-stack"
CHART_LOKI="grafana/loki"
CHART_PROMTAIL="grafana/promtail"

# Values files
VALUES_PROM_STACK="${REPO_ROOT}/helm-values/kube-prometheus-stack.yaml"
VALUES_LOKI="${REPO_ROOT}/helm-values/loki.yaml"
VALUES_PROMTAIL="${REPO_ROOT}/helm-values/promtail.yaml"

# Timeouts
WAIT_OPERATOR=180   # seconds — Prometheus operator deployment
WAIT_GRAFANA=180    # seconds — Grafana deployment
WAIT_PROMETHEUS=300 # seconds — Prometheus StatefulSet (large image pull)
WAIT_LOKI=120       # seconds — Loki StatefulSet
WAIT_PROMTAIL=120   # seconds — Promtail DaemonSet

require kubectl
require helm

printf '%s\n' '' '=== stateful-k8s-recovery-lab: deploy-observability ==='

# ── Pre-flight ────────────────────────────────────────────────────────────────

section "Pre-flight"

if ! command -v k3d &>/dev/null || ! cluster_exists; then
    die "Cluster '${CLUSTER_NAME}' does not exist. Run: make bootstrap"
fi
if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "kubectl cannot reach the cluster. Check context: kubectl config current-context"
fi
ok "Cluster '${CLUSTER_NAME}' is reachable"

# ── Namespace ─────────────────────────────────────────────────────────────────

section "Namespace"

if kubectl get namespace "${NS_OBSERVABILITY}" &>/dev/null 2>&1; then
    ok "Namespace '${NS_OBSERVABILITY}' already exists"
else
    kubectl create namespace "${NS_OBSERVABILITY}"
    ok "Namespace '${NS_OBSERVABILITY}' created"
fi

# ── Helm repos ────────────────────────────────────────────────────────────────

section "Helm repos"

helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana \
    https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
ok "Helm repos up to date"

# ── kube-prometheus-stack ─────────────────────────────────────────────────────

section "kube-prometheus-stack"

info "Running: helm upgrade --install ${RELEASE_PROM_STACK} ${CHART_PROM_STACK} ..."
helm upgrade --install "${RELEASE_PROM_STACK}" "${CHART_PROM_STACK}" \
    --namespace "${NS_OBSERVABILITY}" \
    --values "${VALUES_PROM_STACK}" \
    --timeout 10m \
    --atomic \
    --wait
ok "Release '${RELEASE_PROM_STACK}' deployed"

# ── Loki ──────────────────────────────────────────────────────────────────────

section "Loki"

info "Running: helm upgrade --install ${RELEASE_LOKI} ${CHART_LOKI} ..."
helm upgrade --install "${RELEASE_LOKI}" "${CHART_LOKI}" \
    --namespace "${NS_OBSERVABILITY}" \
    --values "${VALUES_LOKI}" \
    --timeout 5m \
    --atomic \
    --wait
ok "Release '${RELEASE_LOKI}' deployed"

# ── Promtail ──────────────────────────────────────────────────────────────────

section "Promtail"

info "Running: helm upgrade --install ${RELEASE_PROMTAIL} ${CHART_PROMTAIL} ..."
helm upgrade --install "${RELEASE_PROMTAIL}" "${CHART_PROMTAIL}" \
    --namespace "${NS_OBSERVABILITY}" \
    --values "${VALUES_PROMTAIL}" \
    --timeout 5m \
    --atomic \
    --wait
ok "Release '${RELEASE_PROMTAIL}' deployed"

# ── Rollout verification ──────────────────────────────────────────────────────

section "Rollout verification"

# Prometheus operator (Deployment)
info "Waiting for Prometheus operator (timeout: ${WAIT_OPERATOR}s) ..."
kubectl rollout status deployment/"${RELEASE_PROM_STACK}-operator" \
    -n "${NS_OBSERVABILITY}" --timeout="${WAIT_OPERATOR}s"
ok "Prometheus operator is ready"

# Grafana (Deployment)
info "Waiting for Grafana (timeout: ${WAIT_GRAFANA}s) ..."
kubectl rollout status deployment/"${RELEASE_PROM_STACK}-grafana" \
    -n "${NS_OBSERVABILITY}" --timeout="${WAIT_GRAFANA}s"
ok "Grafana is ready"

# Prometheus itself (StatefulSet created by the operator)
PROMETHEUS_STS="prometheus-${RELEASE_PROM_STACK}-prometheus"
info "Waiting for Prometheus StatefulSet '${PROMETHEUS_STS}' (timeout: ${WAIT_PROMETHEUS}s) ..."
kubectl rollout status statefulset/"${PROMETHEUS_STS}" \
    -n "${NS_OBSERVABILITY}" --timeout="${WAIT_PROMETHEUS}s"
ok "Prometheus is ready"

# Loki StatefulSet (SingleBinary)
info "Waiting for Loki StatefulSet (timeout: ${WAIT_LOKI}s) ..."
kubectl rollout status statefulset/"${RELEASE_LOKI}" \
    -n "${NS_OBSERVABILITY}" --timeout="${WAIT_LOKI}s"
ok "Loki is ready"

# Promtail DaemonSet
info "Waiting for Promtail DaemonSet (timeout: ${WAIT_PROMTAIL}s) ..."
kubectl rollout status daemonset/"${RELEASE_PROMTAIL}" \
    -n "${NS_OBSERVABILITY}" --timeout="${WAIT_PROMTAIL}s"
ok "Promtail is ready"

# ── Grafana admin password ────────────────────────────────────────────────────

section "Grafana credentials"

GRAFANA_SECRET="${RELEASE_PROM_STACK}-grafana"
if kubectl get secret "${GRAFANA_SECRET}" -n "${NS_OBSERVABILITY}" &>/dev/null 2>&1; then
    GRAFANA_USER="$(kubectl get secret "${GRAFANA_SECRET}" \
        -n "${NS_OBSERVABILITY}" \
        -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d || echo 'admin')"
    GRAFANA_PASS="$(kubectl get secret "${GRAFANA_SECRET}" \
        -n "${NS_OBSERVABILITY}" \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo '(see secret)')"
    info "User:     ${GRAFANA_USER}"
    info "Password: ${GRAFANA_PASS}"
    info "(LOCAL DEMO ONLY — change before exposing Grafana externally)"
else
    warn "Grafana secret '${GRAFANA_SECRET}' not found — check the release"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf '%s\n' \
    '' \
    '════════════════════════════════════════════════════════════' \
    ' Observability stack deployed' \
    '════════════════════════════════════════════════════════════' \
    '' \
    '  Grafana      — make port-forward TARGET=grafana' \
    '                 http://localhost:3000' \
    '' \
    '  Prometheus   — make port-forward TARGET=prometheus' \
    '                 http://localhost:9090' \
    '' \
    '  Alertmanager — make port-forward TARGET=alertmanager' \
    '                 http://localhost:9093' \
    '' \
    '  Next step: make deploy  (re-deploys app chart to create' \
    '             ServiceMonitor, PrometheusRule, and dashboard)' \
    ''
