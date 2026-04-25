#!/usr/bin/env bash
# install-docker.sh — install Docker Engine on Ubuntu/Debian using the
# official Docker apt repository. Safe to rerun.
# Requires sudo. Does not install Docker Desktop.
#
# Idempotency:
#   - Already installed + daemon reachable → print versions and exit 0.
#   - Installed but daemon not reachable   → print diagnostics and exit 1.
#   - FORCE=1                              → skip the early-exit checks and
#                                            run the full install/repair flow.
set -euo pipefail

FORCE="${FORCE:-0}"

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

# ── Idempotency: check existing Docker installation ───────────────────────────
if [[ "$FORCE" != "1" ]] && command -v docker &>/dev/null; then
    printf '\n=== Docker is already installed ===\n'
    printf '  %s\n' "$(docker --version 2>&1)"
    if docker compose version &>/dev/null 2>&1; then
        printf '  %s\n' "$(docker compose version 2>&1 | head -1)"
    fi

    if docker info &>/dev/null 2>&1; then
        printf '\nDocker Engine is already installed and reachable without sudo. Skipping installation.\n\n'
        exit 0
    else
        printf '\nDocker Engine is installed but the daemon is not reachable without sudo.\n'
        printf 'Possible causes:\n'
        printf '  1. The Docker service is not running:\n'
        printf '       sudo systemctl start docker\n'
        printf '  2. Your user is not in the docker group yet:\n'
        # shellcheck disable=SC2016
        printf '       sudo usermod -aG docker "$USER"\n'
        printf '  3. The shell session predates a group change — a logout/login is needed:\n'
        printf '       newgrp docker   (applies to current session only)\n'
        printf '\nTo force a full reinstall or repair, run:\n'
        printf '  FORCE=1 bash scripts/install-docker.sh\n\n'
        exit 1
    fi
fi

if [[ "$FORCE" == "1" ]]; then
    printf '\nFORCE=1 set — running full install/repair flow. Docker packages may be modified.\n\n'
fi

# ── systemd check ─────────────────────────────────────────────────────────────
if ! command -v systemctl &>/dev/null; then
    printf 'ERROR: systemctl not found.\n' >&2
    printf 'This script uses systemd to enable and start Docker.\n' >&2
    printf 'If you are on WSL2 without systemd, add to /etc/wsl.conf:\n' >&2
    printf '  [boot]\n  systemd=true\n' >&2
    printf 'Then restart WSL: wsl --shutdown   (from Windows)\n' >&2
    exit 1
fi

printf '\nInstalling Docker Engine on %s\n\n' "${PRETTY_NAME:-Ubuntu/Debian}"

# ── Remove conflicting packages ───────────────────────────────────────────────
printf '=== Removing known conflicting packages ===\n'
CONFLICTING=(
    docker.io
    docker-doc
    docker-compose
    docker-compose-v2
    podman-docker
    containerd
    runc
)
for pkg in "${CONFLICTING[@]}"; do
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        printf '  Removing %s...\n' "$pkg"
        sudo apt-get remove -y "$pkg"
    else
        printf '  %-24s not installed, skipping\n' "$pkg"
    fi
done

# ── Install apt dependencies ──────────────────────────────────────────────────
printf '\n=== Installing apt prerequisites ===\n'
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    ca-certificates \
    curl

# ── Add Docker GPG key ────────────────────────────────────────────────────────
printf '\n=== Setting up Docker GPG key ===\n'
KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/docker.asc"

sudo install -m 0755 -d "$KEYRING_DIR"

if [[ -f "$KEYRING_FILE" ]]; then
    printf '  GPG key already present at %s\n' "$KEYRING_FILE"
else
    printf '  Downloading Docker GPG key to %s...\n' "$KEYRING_FILE"
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o "$KEYRING_FILE"
    sudo chmod a+r "$KEYRING_FILE"
    printf '  Done.\n'
fi

# ── Add Docker apt source ─────────────────────────────────────────────────────
printf '\n=== Configuring Docker apt repository ===\n'
SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"

CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ -z "$CODENAME" ]]; then
    printf 'ERROR: Could not determine Ubuntu/Debian codename from /etc/os-release.\n' >&2
    exit 1
fi
ARCH="$(dpkg --print-architecture)"

if [[ -f "$SOURCES_FILE" ]]; then
    printf '  Sources file already present at %s\n' "$SOURCES_FILE"
else
    printf '  Writing Docker apt sources (suite: %s, arch: %s)...\n' \
        "$CODENAME" "$ARCH"
    sudo tee "$SOURCES_FILE" > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${KEYRING_FILE}
EOF
    printf '  Written to %s\n' "$SOURCES_FILE"
fi

# ── Install Docker Engine ─────────────────────────────────────────────────────
printf '\n=== Installing Docker Engine packages ===\n'
sudo apt-get update -qq
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
printf '  Done.\n'

# ── Enable and start Docker service ──────────────────────────────────────────
printf '\n=== Enabling and starting Docker service ===\n'
sudo systemctl enable docker
sudo systemctl start docker
printf '  Docker service enabled and started.\n'

# ── Smoke test (as root via sudo) ─────────────────────────────────────────────
printf '\n=== Verifying Docker Engine with hello-world ===\n'
sudo docker run --rm hello-world

# ── Docker group for non-root access ─────────────────────────────────────────
printf '\n=== Configuring docker group ===\n'
if ! getent group docker &>/dev/null; then
    printf '  Creating docker group...\n'
    sudo groupadd docker
fi

CURRENT_USER="${USER:-$(id -un)}"
if id -nG "$CURRENT_USER" | grep -qw docker; then
    printf '  User "%s" is already in the docker group.\n' "$CURRENT_USER"
else
    printf '  Adding "%s" to the docker group...\n' "$CURRENT_USER"
    sudo usermod -aG docker "$CURRENT_USER"
    printf '  Done.\n'
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n=== Installed versions ===\n'
printf '  %s\n' "$(docker --version)"
printf '  %s\n' "$(docker compose version)"

printf '\n=== Docker service status ===\n'
sudo systemctl status docker --no-pager --lines 5 2>/dev/null || true

printf '\n'
if docker info &>/dev/null 2>&1; then
    printf '  Docker is accessible without sudo. Environment is ready.\n'
    printf '  Run: make check-prereqs\n\n'
else
    printf '  Docker Engine is installed, but it is not yet accessible without sudo.\n'
    printf '  The docker group has been configured. To apply the change:\n'
    printf '\n'
    printf '    Option A (current session): newgrp docker\n'
    printf '    Option B (permanent):       log out and log back in\n'
    printf '\n'
    printf '  Then run: make check-prereqs\n\n'
fi
