#!/usr/bin/env bash
# check-prereqs.sh — verify all required tools and environment conditions.
# Prints PASS/FAIL/WARN for each check. Does not install anything.
set -euo pipefail

PASS="[ PASS ]"
FAIL="[ FAIL ]"
WARN="[ WARN ]"
INFO="[ INFO ]"

all_ok=true
missing_tools=()
docker_missing=false

pass() { printf '%s %s\n' "$PASS" "$1"; }
fail() { printf '%s %s\n' "$FAIL" "$1"; all_ok=false; }
warn() { printf '%s %s\n' "$WARN" "$1"; }
info() { printf '%s %s\n' "$INFO" "$1"; }

has() { command -v "$1" &>/dev/null; }

# ── OS detection ──────────────────────────────────────────────────────────────
printf '\n=== Operating system ===\n'

OS="$(uname -s 2>/dev/null || echo unknown)"
if [[ "$OS" == "Linux" ]]; then
    pass "OS is Linux"
else
    fail "OS is '$OS' — only Linux is supported by these scripts"
fi

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-unknown}"
    VERSION="${VERSION_ID:-unknown}"
    if [[ "$DISTRO" == "ubuntu" ]]; then
        pass "Distribution: Ubuntu ${VERSION}"
    else
        warn "Distribution: ${PRETTY_NAME:-$DISTRO} — scripts are tested on Ubuntu 22.04"
    fi
else
    warn "/etc/os-release not found; cannot detect distribution"
fi

# WSL2 detection (informational only)
if grep -qi microsoft /proc/version 2>/dev/null; then
    if grep -qi "wsl2" /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        info "Running inside WSL2 (distro: ${WSL_DISTRO_NAME:-unknown})"
    else
        info "Running inside WSL (version unclear)"
    fi
fi

# ── CLI tools ─────────────────────────────────────────────────────────────────
printf '\n=== Required CLI tools ===\n'

check_tool() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if has "$cmd"; then
        # Capture version; tolerate non-zero exit (some tools exit 1 for --version)
        local version
        version="$({ "$cmd" --version 2>&1 || true; } | head -1)"
        [[ -z "$version" ]] && version="(version string unavailable)"
        pass "${label}: ${version}"
    else
        fail "${label}: not found"
        missing_tools+=("$cmd")
    fi
}

check_tool bash
check_tool uname
check_tool curl
check_tool jq
check_tool make
check_tool shellcheck

# helm uses a subcommand for version, not --version
if has helm; then
    helm_version="$({ helm version --short 2>&1 || true; } | head -1)"
    [[ -z "$helm_version" ]] && helm_version="(version string unavailable)"
    pass "helm: ${helm_version}"
else
    fail "helm: not found"
    missing_tools+=(helm)
fi

check_tool k3d

# restic uses a subcommand for version, not --version
if has restic; then
    restic_version="$({ restic version 2>&1 || true; } | head -1)"
    [[ -z "$restic_version" ]] && restic_version="(version string unavailable)"
    pass "restic: ${restic_version}"
else
    fail "restic: not found"
    missing_tools+=(restic)
fi

# kubectl uses a subcommand for version, not --version
if has kubectl; then
    kubectl_version="$({ kubectl version --client 2>&1 || true; } | head -1)"
    [[ -z "$kubectl_version" ]] && kubectl_version="(version string unavailable)"
    pass "kubectl: ${kubectl_version}"
else
    fail "kubectl: not found"
    missing_tools+=(kubectl)
fi

# ── Docker ────────────────────────────────────────────────────────────────────
printf '\n=== Docker ===\n'

if has docker; then
    docker_version="$(docker --version 2>&1 || true)"
    pass "docker CLI: ${docker_version}"
else
    fail "docker: not found"
    missing_tools+=(docker)
    docker_missing=true
fi

# docker compose plugin (not the standalone docker-compose binary)
if has docker && docker compose version &>/dev/null 2>&1; then
    compose_version="$(docker compose version 2>&1 | head -1)"
    pass "docker compose plugin: ${compose_version}"
else
    fail "docker compose plugin: not available (install docker-compose-plugin)"
    all_ok=false
fi

# Docker daemon reachability without sudo
if has docker; then
    if docker info &>/dev/null 2>&1; then
        pass "Docker daemon is reachable without sudo"
    else
        fail "Docker daemon is not reachable without sudo"
        info "Fix: sudo usermod -aG docker \$USER   then log out and back in"
        info "     Or run: newgrp docker"
        all_ok=false
    fi
fi

# ── systemd ───────────────────────────────────────────────────────────────────
printf '\n=== System services ===\n'

if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
    pass "systemd is PID 1"
elif command -v systemctl &>/dev/null && systemctl status --no-pager &>/dev/null 2>&1; then
    pass "systemctl is available and responsive"
elif command -v systemctl &>/dev/null; then
    warn "systemctl found but systemd may not be running — install-docker.sh uses systemctl to start Docker"
    info "If you are on WSL2, enable systemd in /etc/wsl.conf: [boot] / systemd=true"
else
    warn "systemctl not found — install-docker.sh requires systemd"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n=== Summary ===\n'

if $all_ok; then
    printf '%s All checks passed. Environment is ready.\n\n' "$PASS"
    exit 0
else
    printf '%s One or more checks failed.\n' "$FAIL"

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        printf '\n  Missing: %s\n' "${missing_tools[*]}"
    fi

    printf '\n  Suggested next steps:\n'

    # Check if any non-docker CLI tool is missing
    non_docker_missing=false
    for t in "${missing_tools[@]}"; do
        if [[ "$t" != "docker" ]]; then
            non_docker_missing=true
            break
        fi
    done

    if $non_docker_missing; then
        printf '    make install-prereqs   # installs kubectl, helm, k3d, restic, shellcheck, curl, jq, make\n'
    fi
    if $docker_missing; then
        printf '    make install-docker    # installs Docker Engine (requires sudo)\n'
    fi
    if ! docker info &>/dev/null 2>&1 && has docker; then
        printf '    newgrp docker          # apply docker group membership without logging out\n'
        printf '    make check-prereqs     # re-check after group change\n'
    fi

    printf '\n'
    exit 1
fi
