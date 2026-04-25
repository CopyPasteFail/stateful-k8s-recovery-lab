#!/usr/bin/env bash
# status.sh -- print cluster, namespace, and pod state.
# Does not fail hard if the cluster does not exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

printf '%s\n' '' '=== stateful-k8s-recovery-lab: status ==='

section "k3d clusters"

if ! command -v k3d &>/dev/null; then
    warn "k3d not found. Run: make install-prereqs"
else
    k3d cluster list
fi

# If the target cluster is absent, nothing further is meaningful
if ! command -v k3d &>/dev/null || ! cluster_exists; then
    printf '%s\n' '' "Cluster '${CLUSTER_NAME}' does not exist." 'Run: make bootstrap' ''
    exit 0
fi

section "kubectl context"

current_ctx="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "${current_ctx}" ]]; then
    warn "No kubectl context is set"
else
    printf '  %s\n' "${current_ctx}"
fi

section "Nodes"

kubectl get nodes 2>/dev/null || warn "Could not retrieve nodes"

section "Namespaces (project)"

printf '  %-24s %s\n' "NAME" "STATUS"
for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
        ns_status="$(kubectl get namespace "${ns}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || printf 'Unknown')"
        printf '  %-24s %s\n' "${ns}" "${ns_status}"
    else
        printf '  %-24s %s\n' "${ns}" "(not created -- run: make bootstrap)"
    fi
done

# Pods per namespace
for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
        section "Pods in ${ns}"
        kubectl get pods -n "${ns}" 2>/dev/null || true
    fi
done

# Helm releases (graceful if helm not installed)
if command -v helm &>/dev/null; then
    section "Helm releases"
    helm list --all-namespaces 2>/dev/null || true
fi

# StatefulSet in leveldb-system
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    section "StatefulSet in ${NS_APP}"
    kubectl get statefulset -n "${NS_APP}" 2>/dev/null || true
fi

# Services in leveldb-system
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    section "Services in ${NS_APP}"
    kubectl get svc -n "${NS_APP}" 2>/dev/null || true
fi

# Services in minio-system (useful for port-forward reference)
if kubectl get namespace "${NS_MINIO}" &>/dev/null 2>&1; then
    section "Services in ${NS_MINIO}"
    kubectl get svc -n "${NS_MINIO}" 2>/dev/null || true
fi

# Backup CronJob in leveldb-system
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    section "Backup CronJob in ${NS_APP}"
    kubectl get cronjob -n "${NS_APP}" \
        -l "app.kubernetes.io/component=backup" \
        2>/dev/null || true
fi

# Recent backup Jobs in leveldb-system
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    section "Backup Jobs in ${NS_APP} (recent)"
    kubectl get jobs -n "${NS_APP}" \
        -l "app.kubernetes.io/component=backup" \
        --sort-by='.metadata.creationTimestamp' \
        2>/dev/null || true
fi

# Recent restore Jobs in leveldb-system
if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
    RESTORE_JOB_COUNT="$(kubectl get jobs -n "${NS_APP}" \
        -l "app.kubernetes.io/component=restore" \
        --no-headers 2>/dev/null | wc -l || true)"
    if [[ "${RESTORE_JOB_COUNT}" -gt 0 ]]; then
        section "Restore Jobs in ${NS_APP} (recent)"
        kubectl get jobs -n "${NS_APP}" \
            -l "app.kubernetes.io/component=restore" \
            --sort-by='.metadata.creationTimestamp' \
            2>/dev/null || true
    fi
fi

# Services in observability
if kubectl get namespace "${NS_OBSERVABILITY}" &>/dev/null 2>&1; then
    section "Services in ${NS_OBSERVABILITY}"
    kubectl get svc -n "${NS_OBSERVABILITY}" 2>/dev/null || true
fi

# ServiceMonitors — only if the CRD is installed (requires kube-prometheus-stack)
if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null 2>&1; then
    if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
        section "ServiceMonitors in ${NS_APP}"
        kubectl get servicemonitors -n "${NS_APP}" 2>/dev/null || true
    fi
else
    info "ServiceMonitor CRD not present (run: make deploy-observability)"
fi

# PrometheusRules — only if the CRD is installed
if kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null 2>&1; then
    if kubectl get namespace "${NS_APP}" &>/dev/null 2>&1; then
        section "PrometheusRules in ${NS_APP}"
        kubectl get prometheusrules -n "${NS_APP}" 2>/dev/null || true
    fi
fi

# PVCs across project namespaces
for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "${ns}" &>/dev/null 2>&1; then
        pvc_count="$(kubectl get pvc -n "${ns}" --no-headers 2>/dev/null | wc -l || true)"
        if [[ "${pvc_count}" -gt 0 ]]; then
            section "PVCs in ${ns}"
            kubectl get pvc -n "${ns}" 2>/dev/null || true
        fi
    fi
done

printf '\n'
