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

# Set the toggle indicating launched from start-here.sh
export LAUNCHED_FROM_START_HERE=1

# Call the main build script with all arguments passed through
exec "$(dirname "$0")/scripts/build.sh" "$@"
