#!/usr/bin/env bash
# port-forward.sh — kubectl port-forward for one cluster service.
#
# Usage (via make):
#   make port-forward                       print available targets
#   make port-forward TARGET=app            App API      -> http://localhost:18081
#   make port-forward TARGET=minio-api      MinIO API    -> http://localhost:9000
#   make port-forward TARGET=minio-console  MinIO Console-> http://localhost:9001
#   make port-forward TARGET=grafana        Grafana      -> http://localhost:3000
#   make port-forward TARGET=prometheus     Prometheus   -> http://localhost:9090
#   make port-forward TARGET=alertmanager   Alertmanager -> http://localhost:9093
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/port-forward-common.sh
source "${SCRIPT_DIR}/lib/port-forward-common.sh"

TARGET="${TARGET:-}"

require kubectl

case "${TARGET}" in
    app|minio-api|minio-console|grafana|prometheus|alertmanager)
        service="$(port_forward_target_service "${TARGET}")"
        namespace="$(port_forward_target_namespace "${TARGET}")"
        local_port="$(port_forward_target_local_port "${TARGET}")"
        service_port="$(port_forward_target_service_port "${TARGET}")"

        if ! kubectl get svc "${service}" --namespace "${namespace}" &>/dev/null; then
            case "${TARGET}" in
                app) die "App service not found in '${NS_APP}'. Run: make deploy" ;;
                minio-api|minio-console) die "MinIO service not found in '${NS_MINIO}'. Run: make deploy-minio" ;;
                grafana|prometheus|alertmanager) die "Observability service not found in '${NS_OBSERVABILITY}'. Run: make deploy-observability" ;;
            esac
        fi

        info "Forwarding $(port_forward_target_title "${TARGET}"): http://localhost:${local_port}  (Press Ctrl-C to stop)"
        port_forward_print_credentials_for_targets "${TARGET}"
        exec kubectl port-forward "svc/${service}" "${local_port}:${service_port}" \
            --namespace "${namespace}" \
            --address 127.0.0.1
        ;;

    "")
        port_forward_print_available_targets
        ;;

    *)
        warn "Unknown target: '${TARGET}'"
        port_forward_print_available_targets
        exit 1
        ;;
esac
