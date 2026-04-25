#!/usr/bin/env bash
# install-prereqs.sh — install missing CLI tools required by this project.
# Does NOT install Docker; run 'make install-docker' for that.
# Safe to rerun: already-installed tools are skipped.
set -euo pipefail

has() { command -v "$1" &>/dev/null; }

# ── OS / distro check ─────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
    printf 'ERROR: This script only supports Linux.\n' >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    printf 'ERROR: /etc/os-release not found; cannot detect distribution.\n' >&2
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    printf 'ERROR: Only Ubuntu/Debian-based systems are supported (detected: %s).\n' \
        "${PRETTY_NAME:-${ID:-unknown}}" >&2
    exit 1
fi

printf '\nInstalling prerequisites on %s\n' "${PRETTY_NAME:-Ubuntu/Debian}"
printf 'Docker will not be installed here. Run: make install-docker\n\n'

# ── apt packages ──────────────────────────────────────────────────────────────
printf '=== apt packages (curl, ca-certificates, gnupg, jq, make, restic, shellcheck) ===\n'
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    jq \
    make \
    restic \
    shellcheck
printf '  Done.\n'

# ── kubectl ───────────────────────────────────────────────────────────────────
printf '\n=== kubectl ===\n'
if has kubectl; then
    printf '  Already installed: %s\n' \
        "$(kubectl version --client 2>&1 | head -1)"
else
    printf '  Fetching latest stable version...\n'
    KUBECTL_VERSION="$(curl -sSfL https://dl.k8s.io/release/stable.txt)"
    ARCH="$(dpkg --print-architecture)"
    printf '  Downloading kubectl %s (%s)...\n' "$KUBECTL_VERSION" "$ARCH"
    curl -sSfLo /tmp/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    printf '  Installed kubectl %s\n' "$KUBECTL_VERSION"
fi

# ── Helm ──────────────────────────────────────────────────────────────────────
printf '\n=== Helm ===\n'
if has helm; then
    printf '  Already installed: %s\n' "$(helm version --short 2>/dev/null || true)"
else
    printf '  Installing Helm via official install script...\n'
    curl -sSfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | bash
fi

# ── k3d ───────────────────────────────────────────────────────────────────────
printf '\n=== k3d ===\n'
if has k3d; then
    printf '  Already installed: %s\n' \
        "$(k3d version 2>/dev/null | head -1 || true)"
else
    printf '  Installing k3d via official install script...\n'
    curl -sSfL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
        | bash
fi

# ── Installed versions summary ────────────────────────────────────────────────
printf '\n=== Installed versions ===\n'

_ver() {
    local cmd="$1"; shift          # remaining args are the version command
    if has "$cmd"; then
        printf '  %-10s %s\n' "${cmd}:" "$("$@" 2>&1 | head -1 || true)"
    else
        printf '  %-10s NOT FOUND — installation may have failed\n' "${cmd}:"
    fi
}

_ver curl      curl --version
_ver jq        jq --version
_ver make      make --version
_ver shellcheck shellcheck --version
_ver kubectl   kubectl version --client
_ver helm      helm version --short
_ver k3d       k3d version
_ver restic    restic version

# ── inotify limits (required by Promtail on k3d / WSL2) ─────────────────────
# Promtail's file target manager creates one inotify instance per watched
# directory. The kernel default (128) is too low for a node running many pods.
# This persists the limits across reboots via /etc/sysctl.d/.
printf '\n=== inotify limits (Promtail / k3d) ===\n'
SYSCTL_CONF="/etc/sysctl.d/99-k3d-inotify.conf"
if [[ -f "${SYSCTL_CONF}" ]]; then
    printf '  Already configured: %s\n' "${SYSCTL_CONF}"
else
    printf '  Writing %s ...\n' "${SYSCTL_CONF}"
    printf 'fs.inotify.max_user_instances=512\nfs.inotify.max_user_watches=524288\n' \
        | sudo tee "${SYSCTL_CONF}" > /dev/null
    sudo sysctl -p "${SYSCTL_CONF}"
    printf '  Done.\n'
fi

printf '\nDone. To install Docker Engine, run: make install-docker\n'
printf 'To verify the full environment, run:  make check-prereqs\n\n'
