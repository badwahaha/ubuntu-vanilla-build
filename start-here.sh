#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# Clear the terminal screen (if stdout is a TTY)
if [[ -t 1 ]]; then
    clear || true
fi

# Determine if running on a Debian-based host (excluding Ubuntu-based)
IS_DEBIAN_OR_UBUNTU=0
IS_DEBIAN=0
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
        IS_DEBIAN_OR_UBUNTU=1
    elif [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
        IS_DEBIAN_OR_UBUNTU=1
        # Exclude Ubuntu-based distros (e.g. Linux Mint based on Ubuntu)
        if [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *ubuntu* ]]; then
            IS_DEBIAN=1
        fi
    fi
fi

# Only perform Debian/Ubuntu dependency checks if on a supported Debian/Ubuntu host
if [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]] && command -v dpkg &>/dev/null; then
    # Define dependencies
    DEPS=("debootstrap" "squashfs-tools" "xorriso")
    if [[ "$IS_DEBIAN" -eq 1 ]]; then
        DEPS+=("ubuntu-archive-keyring")
    fi

    # Check for missing dependencies
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! dpkg -s "$dep" &>/dev/null; then
            MISSING_DEPS+=("$dep")
        fi
    done

    # If there are missing dependencies, update and install them
    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo "=====> Installing missing host dependencies: ${MISSING_DEPS[*]}"
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update
            apt-get install -y "${MISSING_DEPS[@]}"
        else
            sudo apt-get update
            sudo apt-get install -y "${MISSING_DEPS[@]}"
        fi
    fi
fi

# ── Sudo keep-alive ──────────────────────────────────────────────────
# Long builds (especially on WSL2) can outlast the default sudo timeout.
# We validate credentials once up front, then refresh them in the
# background so privileged steps never stall waiting for a password.
SUDO_KEEPALIVE_PID=""

cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

if [[ "$(id -u)" -ne 0 ]]; then
    echo "=====> Requesting sudo credentials (will be kept alive for the entire build) ..."
    if ! sudo -v 2>/dev/null; then
        echo "=====> ERROR: Failed to obtain sudo credentials. The build requires sudo access." >&2
        exit 1
    fi

    # Background loop: refresh sudo timestamp every 60 seconds
    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!

    trap cleanup_sudo_keepalive EXIT
fi

# Set the toggle indicating launched from start-here.sh
export LAUNCHED_FROM_START_HERE=1

# Call the main build script with all arguments passed through.
# Use a regular invocation (not exec) so the EXIT trap can clean up the
# sudo keep-alive background process when the build finishes.
"$(dirname "$0")/scripts/build.sh" "$@"
