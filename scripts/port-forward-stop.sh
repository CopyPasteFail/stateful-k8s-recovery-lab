#!/usr/bin/env bash
# port-forward-stop.sh — stop all tracked background kubectl port-forward processes.
#
# Usage (via make):
#   make port-forward-stop  stop every tracked background forward
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/port-forward-common.sh
source "${SCRIPT_DIR}/lib/port-forward-common.sh"

mkdir -p "${PORT_FORWARD_STATE_DIR}"

stopped_targets=()

for target in "${PORT_FORWARD_TARGETS[@]}"; do
    if [[ -f "$(port_forward_pid_file "${target}")" ]]; then
        port_forward_stop "${target}"
        stopped_targets+=("${target}")
    fi
done

if ((${#stopped_targets[@]} == 0)); then
    info "No tracked port-forward processes were running."
else
    info "Stopped: ${stopped_targets[*]}"
fi
