#!/usr/bin/env bash
# port-forward.sh — kubectl port-forward for cluster services.
#
# Usage (via make):
#   make port-forward                       print available targets
#   make port-forward TARGET=app            App API      -> http://localhost:8080
#   make port-forward TARGET=minio-api      MinIO API    -> http://localhost:9000
#   make port-forward TARGET=minio-console  MinIO Console-> http://localhost:9001
#   make port-forward TARGET=grafana        Grafana      -> http://localhost:3000
#   make port-forward TARGET=prometheus     Prometheus   -> http://localhost:9090
#   make port-forward TARGET=alertmanager   Alertmanager -> http://localhost:9093
#
# The TARGET variable is passed from the Make command line and is available
# as an environment variable in this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TARGET="${TARGET:-}"

require kubectl

# ── helpers ───────────────────────────────────────────────────────────────────

_svc_exists() {
    local svc="$1" ns="$2"
    kubectl get svc "${svc}" --namespace "${ns}" &>/dev/null 2>&1
}

_print_targets() {
    printf '%s\n' '' '=== stateful-k8s-recovery-lab: port-forward ===' ''
    printf 'Available targets:\n\n'

    local found=0

    if _svc_exists leveldb-app "${NS_APP}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=app' \
            'App API          -> http://localhost:8080'
        found=1
    fi

    if _svc_exists minio "${NS_MINIO}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=minio-api' \
            'MinIO API (S3)   -> http://localhost:9000'
        found=1
    fi

    if _svc_exists minio-console "${NS_MINIO}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=minio-console' \
            'MinIO Console    -> http://localhost:9001'
        found=1
    fi

    if _svc_exists kube-prometheus-stack-grafana "${NS_OBSERVABILITY}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=grafana' \
            'Grafana          -> http://localhost:3000'
        found=1
    fi

    if _svc_exists prometheus-operated "${NS_OBSERVABILITY}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=prometheus' \
            'Prometheus       -> http://localhost:9090'
        found=1
    fi

    if _svc_exists alertmanager-operated "${NS_OBSERVABILITY}"; then
        printf '  %-44s %s\n' \
            'make port-forward TARGET=alertmanager' \
            'Alertmanager     -> http://localhost:9093'
        found=1
    fi

    if [[ "${found}" -eq 0 ]]; then
        info "No services available yet."
        info "Run: make deploy  and/or  make deploy-minio  and/or  make deploy-observability"
    fi

    printf '\n'
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${TARGET}" in
    app)
        if ! _svc_exists leveldb-app "${NS_APP}"; then
            die "App service not found in '${NS_APP}'. Run: make deploy"
        fi
        info "Forwarding App API: http://localhost:8080  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/leveldb-app 8080:8080 --namespace "${NS_APP}"
        ;;

    minio-api)
        if ! _svc_exists minio "${NS_MINIO}"; then
            die "MinIO API service not found in '${NS_MINIO}'. Run: make deploy-minio"
        fi
        info "Forwarding MinIO API: http://localhost:9000  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/minio 9000:9000 --namespace "${NS_MINIO}"
        ;;

    minio-console)
        if ! _svc_exists minio-console "${NS_MINIO}"; then
            die "MinIO console service not found in '${NS_MINIO}'. Run: make deploy-minio"
        fi
        info "Forwarding MinIO Console: http://localhost:9001  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/minio-console 9001:9001 --namespace "${NS_MINIO}"
        ;;

    grafana)
        if ! _svc_exists kube-prometheus-stack-grafana "${NS_OBSERVABILITY}"; then
            die "Grafana service not found in '${NS_OBSERVABILITY}'. Run: make deploy-observability"
        fi
        info "Forwarding Grafana: http://localhost:3000  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 \
            --namespace "${NS_OBSERVABILITY}"
        ;;

    prometheus)
        if ! _svc_exists prometheus-operated "${NS_OBSERVABILITY}"; then
            die "Prometheus service not found in '${NS_OBSERVABILITY}'. Run: make deploy-observability"
        fi
        info "Forwarding Prometheus: http://localhost:9090  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/prometheus-operated 9090:9090 \
            --namespace "${NS_OBSERVABILITY}"
        ;;

    alertmanager)
        if ! _svc_exists alertmanager-operated "${NS_OBSERVABILITY}"; then
            die "Alertmanager service not found in '${NS_OBSERVABILITY}'. Run: make deploy-observability"
        fi
        info "Forwarding Alertmanager: http://localhost:9093  (Press Ctrl-C to stop)"
        exec kubectl port-forward svc/alertmanager-operated 9093:9093 \
            --namespace "${NS_OBSERVABILITY}"
        ;;

    "")
        _print_targets
        ;;

    *)
        warn "Unknown target: '${TARGET}'"
        _print_targets
        exit 1
        ;;
esac
