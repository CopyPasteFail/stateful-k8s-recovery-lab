#!/usr/bin/env bash
# port-forward-all.sh — start all available kubectl port-forward processes in the background.
#
# Usage (via make):
#   make port-forward-all   start all currently available forwards
#   make port-forward-stop  stop all tracked background forwards
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/port-forward-common.sh
source "${SCRIPT_DIR}/lib/port-forward-common.sh"

require kubectl

mkdir -p "${PORT_FORWARD_STATE_DIR}"

started_targets=()
skipped_targets=()
reused_targets=()

cleanup_started_forwards() {
    local target
    for target in "${started_targets[@]}"; do
        port_forward_stop "${target}"
    done
}

trap cleanup_started_forwards EXIT

for target in "${PORT_FORWARD_TARGETS[@]}"; do
    if port_forward_start "${target}"; then
        started_targets+=("${target}")
    else
        status="$?"
        case "${status}" in
            1)
                skipped_targets+=("${target}")
                info "$(port_forward_target_title "${target}") is not available yet; skipping"
                ;;
            2)
                reused_targets+=("${target}")
                ;;
            *)
                die "Unexpected port-forward status for '${target}'"
                ;;
        esac
    fi
done

trap - EXIT

printf '\n'
if ((${#started_targets[@]} > 0)); then
    info "Started: ${started_targets[*]}"
fi
if ((${#skipped_targets[@]} > 0)); then
    info "Skipped: ${skipped_targets[*]}"
fi
if ((${#reused_targets[@]} > 0)); then
    info "Already running: ${reused_targets[*]}"
fi
port_forward_print_credentials_for_targets "${started_targets[@]}" "${reused_targets[@]}"
info "Use 'make port-forward-stop' to stop the background forwards."
