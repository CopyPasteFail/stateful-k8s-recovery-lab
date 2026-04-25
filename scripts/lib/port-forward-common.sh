#!/usr/bin/env bash
# port-forward-common.sh — shared port-forward target definitions and process helpers.
# Source this file; do not execute it directly.
# Callers must set SCRIPT_DIR before sourcing.

# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

PORT_FORWARD_STATE_DIR="/tmp/stateful-k8s-recovery-lab/port-forwards"

PORT_FORWARD_TARGETS=("app" "minio-api" "minio-console" "grafana" "prometheus" "alertmanager")

port_forward_target_title() {
    case "$1" in
        app) printf '%s\n' 'App API' ;;
        minio-api) printf '%s\n' 'MinIO API' ;;
        minio-console) printf '%s\n' 'MinIO Console' ;;
        grafana) printf '%s\n' 'Grafana' ;;
        prometheus) printf '%s\n' 'Prometheus' ;;
        alertmanager) printf '%s\n' 'Alertmanager' ;;
        *) return 1 ;;
    esac
}

port_forward_target_service() {
    case "$1" in
        app) printf '%s\n' 'leveldb-app' ;;
        minio-api) printf '%s\n' 'minio' ;;
        minio-console) printf '%s\n' 'minio-console' ;;
        grafana) printf '%s\n' 'kube-prometheus-stack-grafana' ;;
        prometheus) printf '%s\n' 'prometheus-operated' ;;
        alertmanager) printf '%s\n' 'alertmanager-operated' ;;
        *) return 1 ;;
    esac
}

port_forward_target_namespace() {
    case "$1" in
        app) printf '%s\n' "${NS_APP}" ;;
        minio-api|minio-console) printf '%s\n' "${NS_MINIO}" ;;
        grafana|prometheus|alertmanager) printf '%s\n' "${NS_OBSERVABILITY}" ;;
        *) return 1 ;;
    esac
}

port_forward_target_local_port() {
    case "$1" in
        app) printf '%s\n' '18081' ;;
        minio-api) printf '%s\n' '9000' ;;
        minio-console) printf '%s\n' '9001' ;;
        grafana) printf '%s\n' '3000' ;;
        prometheus) printf '%s\n' '9090' ;;
        alertmanager) printf '%s\n' '9093' ;;
        *) return 1 ;;
    esac
}

port_forward_target_service_port() {
    case "$1" in
        app) printf '%s\n' '8080' ;;
        minio-api|minio-console|prometheus|alertmanager) printf '%s\n' "$(port_forward_target_local_port "$1")" ;;
        grafana) printf '%s\n' '80' ;;
        *) return 1 ;;
    esac
}

port_forward_secret_value() {
    local secret_name="$1"
    local namespace="$2"
    local secret_key="$3"

    kubectl get secret "${secret_name}" \
        --namespace "${namespace}" \
        -o "jsonpath={.data.${secret_key}}" 2>/dev/null | base64 -d
}

port_forward_pid_file() {
    local target="$1"
    printf '%s/%s.pid\n' "${PORT_FORWARD_STATE_DIR}" "${target}"
}

port_forward_log_file() {
    local target="$1"
    printf '%s/%s.log\n' "${PORT_FORWARD_STATE_DIR}" "${target}"
}

port_forward_is_running() {
    local pid_file
    pid_file="$(port_forward_pid_file "$1")"
    if [[ ! -f "${pid_file}" ]]; then
        return 1
    fi

    local pid
    pid="$(<"${pid_file}")"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${pid}" &>/dev/null
}

port_forward_wait_until_ready() {
    local target="$1"
    local local_port
    local_port="$(port_forward_target_local_port "${target}")"

    local attempt=0
    local max_attempts=30
    local pid_file
    pid_file="$(port_forward_pid_file "${target}")"
    local pid
    pid="$(<"${pid_file}")"
    local log_file
    log_file="$(port_forward_log_file "${target}")"

    while (( attempt < max_attempts )); do
        if ! kill -0 "${pid}" &>/dev/null; then
            rm -f "${pid_file}"
            die "Port-forward '${target}' exited before becoming ready. See ${log_file}"
        fi

        if (: <"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
            return 0
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    rm -f "${pid_file}"
    die "Port-forward '${target}' did not become ready on localhost:${local_port}. See ${log_file}"
}

port_forward_start() {
    local target="$1"
    local service namespace local_port service_port

    service="$(port_forward_target_service "${target}")" || die "Unknown port-forward target: '${target}'"
    namespace="$(port_forward_target_namespace "${target}")" || die "Unknown port-forward target: '${target}'"
    local_port="$(port_forward_target_local_port "${target}")" || die "Unknown port-forward target: '${target}'"
    service_port="$(port_forward_target_service_port "${target}")" || die "Unknown port-forward target: '${target}'"

    if ! kubectl get svc "${service}" --namespace "${namespace}" &>/dev/null; then
        return 1
    fi

    mkdir -p "${PORT_FORWARD_STATE_DIR}"

    local pid_file
    pid_file="$(port_forward_pid_file "${target}")"
    local log_file
    log_file="$(port_forward_log_file "${target}")"

    if port_forward_is_running "${target}"; then
        info "${target} already forwarding on http://localhost:${local_port}"
        return 2
    fi

    if [[ -f "${pid_file}" ]]; then
        rm -f "${pid_file}"
    fi

    info "Forwarding $(port_forward_target_title "${target}"): http://localhost:${local_port}"
    setsid kubectl port-forward "svc/${service}" "${local_port}:${service_port}" \
        --namespace "${namespace}" \
        --address 127.0.0.1 \
        >"${log_file}" 2>&1 < /dev/null &
    printf '%s\n' "$!" >"${pid_file}"
    port_forward_wait_until_ready "${target}"
}

# Stop a tracked background forward by pidfile, but tolerate already-exited
# processes so repeated cleanup runs stay idempotent.
port_forward_stop() {
    local target="$1"
    local pid_file
    pid_file="$(port_forward_pid_file "${target}")"
    local log_file
    log_file="$(port_forward_log_file "${target}")"

    if [[ ! -f "${pid_file}" ]]; then
        return 0
    fi

    local pid
    pid="$(<"${pid_file}")"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" &>/dev/null; then
        kill "${pid}" || true
        local attempt=0
        while (( attempt < 10 )); do
            if ! kill -0 "${pid}" &>/dev/null; then
                break
            fi
            sleep 1
            attempt=$((attempt + 1))
        done

        if kill -0 "${pid}" &>/dev/null; then
            kill -9 "${pid}" || true
        fi
    fi

    rm -f "${pid_file}"

    if [[ -f "${log_file}" ]]; then
        info "Stopped $(port_forward_target_title "${target}") port-forward. Log kept at ${log_file}"
    fi
}

# Print the user-facing port-forward commands that are currently available.
port_forward_print_available_targets() {
    printf '%s\n' '' '=== stateful-k8s-recovery-lab: port-forward ===' ''
    printf 'Available targets:\n\n'

    local found=0
    local target
    for target in "${PORT_FORWARD_TARGETS[@]}"; do
        local service namespace title local_port
        service="$(port_forward_target_service "${target}")"
        namespace="$(port_forward_target_namespace "${target}")"
        title="$(port_forward_target_title "${target}")"
        local_port="$(port_forward_target_local_port "${target}")"

        if kubectl get svc "${service}" --namespace "${namespace}" &>/dev/null; then
            printf '  %-44s %s\n' \
                "make port-forward TARGET=${target}" \
                "${title} -> http://localhost:${local_port}"
            found=1
        fi
    done

    if [[ "${found}" -eq 0 ]]; then
        info "No services available yet."
        info "Run: make deploy  and/or  make deploy-minio  and/or  make deploy-observability"
    fi

    printf '\n'
    printf '  %-44s %s\n' \
        'make port-forward-all' \
        'Start every available forward in the background'
    printf '  %-44s %s\n' \
        'make port-forward-stop' \
        'Stop every tracked background forward'
    printf '\n'
}

port_forward_print_credentials_for_target() {
    local target="$1"

    case "${target}" in
        grafana)
            local grafana_secret="kube-prometheus-stack-grafana"
            if ! kubectl get secret "${grafana_secret}" --namespace "${NS_OBSERVABILITY}" &>/dev/null; then
                warn "Grafana credentials secret '${grafana_secret}' not found"
                return 0
            fi

            local grafana_user grafana_password
            grafana_user="$(port_forward_secret_value "${grafana_secret}" "${NS_OBSERVABILITY}" "admin-user")"
            grafana_password="$(port_forward_secret_value "${grafana_secret}" "${NS_OBSERVABILITY}" "admin-password")"

            printf '  %-14s %s\n' 'Grafana:' "http://localhost:3000"
            printf '  %-14s %s\n' 'User:' "${grafana_user}"
            printf '  %-14s %s\n' 'Password:' "${grafana_password}"
            ;;

        minio-console)
            local minio_secret="minio"
            if ! kubectl get secret "${minio_secret}" --namespace "${NS_MINIO}" &>/dev/null; then
                warn "MinIO credentials secret '${minio_secret}' not found"
                return 0
            fi

            local minio_user minio_password
            minio_user="$(port_forward_secret_value "${minio_secret}" "${NS_MINIO}" "rootUser")"
            minio_password="$(port_forward_secret_value "${minio_secret}" "${NS_MINIO}" "rootPassword")"

            printf '  %-14s %s\n' 'MinIO Console:' "http://localhost:9001"
            printf '  %-14s %s\n' 'User:' "${minio_user}"
            printf '  %-14s %s\n' 'Password:' "${minio_password}"
            ;;
    esac
}

port_forward_print_credentials_for_targets() {
    local printed_header=0
    local target

    for target in "$@"; do
        case "${target}" in
            grafana|minio-console)
                if [[ "${printed_header}" -eq 0 ]]; then
                    printf '\n'
                    info "UI credentials (local demo only):"
                    printed_header=1
                else
                    printf '\n'
                fi
                port_forward_print_credentials_for_target "${target}"
                ;;
        esac
    done
}
