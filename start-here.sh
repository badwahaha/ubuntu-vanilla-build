#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# ── Help ─────────────────────────────────────────────────────────────
# start-here.sh is a thin dispatcher: it picks a distro (Ubuntu / Pop!_OS)
# and an output type (ISO / cloud image / VM image), then runs the matching
# builder in scripts/ with every other argument passed straight through.
# --help is handled here (before any sudo/dependency work) and explains the
# dispatcher; per-builder options are shown by each builder's own --help.
show_start_help() {
    local self="$0"
    cat <<EOF
start-here.sh — guided launcher for the Ubuntu / Pop!_OS image builders.

It asks two things (or takes them as flags), then hands off to the matching
script in scripts/ with all remaining arguments passed through unchanged.

Usage:
  ${self} [--distro=ubuntu|popos] [--output=iso|img|vm] [builder options...]
  ${self} --create-config [--distro=...] [--output=...]
  ${self} --help

Dispatcher options:
  --distro=ubuntu|popos     Which distribution to build (default: asked on a TTY,
                            else ubuntu). Env: BUILD_DISTRO.
  --output=iso|img|vm       What to produce (default: asked on a TTY, else iso).
                            Env: BUILD_OUTPUT.
                              iso  Live-installer ISO (USB / DVD / PXE / VM boot)
                              img  Cloud disk image: raw .img for cloud VMs (cloud-init)
                              vm   VM disk image: raw .img + QCOW2/VDI/VMDK/VHDX exports
  --create-config           Only run the selected builder's config wizard
    (--generate-config)     (no sudo, no host dependencies installed).
  -h, --help                Show this help and exit.

distro + output map to these builders (run one directly if you prefer):
  ubuntu iso  ->  scripts/build.sh            popos iso  ->  scripts/build-popos.sh
  ubuntu img  ->  scripts/build-img.sh        popos img  ->  scripts/build-popos-img.sh
  ubuntu vm   ->  scripts/build-vm.sh         popos vm   ->  scripts/build-popos-vm.sh

All other options (--release, --kernel, --desktop, browsers, and for images
--firmware, --disk-size, --profile, --network, --alloc-tool, --user-mode,
--formats, ...) belong to the builders and are forwarded verbatim. For the full,
output-specific list run the matching builder's own help, e.g.:
  scripts/build.sh --help          (ISO options + stages)
  scripts/build-img.sh --help      (cloud image options + stages)
  scripts/build-vm.sh --help       (VM image options + stages)

Examples:
  ${self}                                     Fully guided (asks distro + output)
  ${self} --distro=popos --output=vm          Pop!_OS VM image, then guided prompts
  ${self} --output=img --release=noble --profile=cli -
  ${self} --create-config --distro=ubuntu --output=vm
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_start_help
            exit 0
            ;;
    esac
done

# Clear the terminal screen (if stdout is a TTY)
if [[ -t 1 ]]; then
    clear || true
fi

# ── Config-wizard shortcut ───────────────────────────────────────────
# "./start-here.sh --create-config" (or --generate-config) only runs the
# builder's config wizard: no host dependencies or sudo credentials are
# needed, so both setup steps below are skipped. The distro question is
# still asked first, then the chosen builder is invoked with
# --generate-config.
GENERATE_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        --create-config|--generate-config) GENERATE_CONFIG=1 ;;
    esac
done

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
if [[ "$GENERATE_CONFIG" -eq 0 ]] && [[ "$IS_DEBIAN_OR_UBUNTU" -eq 1 ]] && command -v dpkg &>/dev/null; then
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

if [[ "$GENERATE_CONFIG" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
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

# ── Distro selection ─────────────────────────────────────────────────
# Choose which image to build: Ubuntu (scripts/build.sh) or Pop!_OS
# (scripts/build-popos.sh). Selectable via --distro=ubuntu|popos, the
# BUILD_DISTRO env var, or an interactive prompt on a TTY (default: ubuntu).
# The output type — live-installer ISO, cloud disk image (.img), or VM disk
# image (raw + QCOW2/VDI/VMDK/VHDX) — is selectable via --output=iso|img|vm,
# the BUILD_OUTPUT env var, or an interactive prompt (default: iso).
BUILD_DISTRO="${BUILD_DISTRO:-}"
BUILD_OUTPUT="${BUILD_OUTPUT:-}"
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --distro=*)       BUILD_DISTRO="${arg#--distro=}" ;;
        --output=*)       BUILD_OUTPUT="${arg#--output=}" ;;
        # Translated to the builders' --generate-config below; keep it out of
        # PASS_ARGS so it is not forwarded twice.
        --create-config|--generate-config) ;;
        *)                PASS_ARGS+=("$arg") ;;
    esac
done
if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
    PASS_ARGS+=("--generate-config")
fi

case "${BUILD_DISTRO,,}" in
    pop|pop-os|pop_os|popos) BUILD_DISTRO="popos" ;;
    ubuntu)                  BUILD_DISTRO="ubuntu" ;;
    "")
        if [[ -t 0 ]]; then
            echo ""
            echo "--- Distribution ---"
            if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
                echo "    (config wizard: choose which builder to generate a config for)"
            fi
            echo "    1) Ubuntu   Vanilla Ubuntu (scripts/build*.sh)  [default]"
            echo "    2) Pop!_OS  Pop!_OS from apt.pop-os.org repos (scripts/build-popos*.sh)"
            while true; do
                read -r -p "  Distro [1/2, Enter=1]: " _choice
                case "${_choice,,}" in
                    ""|1|u|ubuntu)           BUILD_DISTRO="ubuntu"; break ;;
                    2|p|pop|pop-os|popos)    BUILD_DISTRO="popos";  break ;;
                    *) echo "  Invalid selection: '${_choice}'." ;;
                esac
            done
        else
            BUILD_DISTRO="ubuntu"
        fi
        ;;
    *)
        echo "ERROR: BUILD_DISTRO/--distro must be 'ubuntu' or 'popos' (got: '${BUILD_DISTRO}')." >&2
        exit 1
        ;;
esac

# ── Output type selection ────────────────────────────────────────────
case "${BUILD_OUTPUT,,}" in
    iso)          BUILD_OUTPUT="iso" ;;
    img|image|cloud|cloud-img) BUILD_OUTPUT="img" ;;
    vm)           BUILD_OUTPUT="vm" ;;
    "")
        if [[ -t 0 ]]; then
            echo ""
            echo "--- Output type ---"
            echo "    1) ISO           Live-installer ISO (USB/DVD/PXE/VM boot)  [default]"
            echo "    2) Cloud image   Ready-to-deploy raw .img for cloud VMs (cloud-init)"
            echo "    3) VM image      Raw .img + QCOW2/VDI/VMDK/VHDX exports for hypervisors"
            while true; do
                read -r -p "  Output [1/2/3, Enter=1]: " _choice
                case "${_choice,,}" in
                    ""|1|iso)                       BUILD_OUTPUT="iso"; break ;;
                    2|img|image|cloud|cloud-img)    BUILD_OUTPUT="img"; break ;;
                    3|vm)                           BUILD_OUTPUT="vm";  break ;;
                    *) echo "  Invalid selection: '${_choice}'." ;;
                esac
            done
        else
            BUILD_OUTPUT="iso"
        fi
        ;;
    *)
        echo "ERROR: BUILD_OUTPUT/--output must be 'iso', 'img', or 'vm' (got: '${BUILD_OUTPUT}')." >&2
        exit 1
        ;;
esac

case "${BUILD_DISTRO}-${BUILD_OUTPUT}" in
    ubuntu-iso) BUILD_SCRIPT="build.sh" ;;
    ubuntu-img) BUILD_SCRIPT="build-img.sh" ;;
    ubuntu-vm)  BUILD_SCRIPT="build-vm.sh" ;;
    popos-iso)  BUILD_SCRIPT="build-popos.sh" ;;
    popos-img)  BUILD_SCRIPT="build-popos-img.sh" ;;
    popos-vm)   BUILD_SCRIPT="build-popos-vm.sh" ;;
esac
echo "=====> Selected: ${BUILD_DISTRO} / ${BUILD_OUTPUT} (scripts/${BUILD_SCRIPT})"

# Call the selected build script with all remaining arguments passed through.
# Use a regular invocation (not exec) so the EXIT trap can clean up the
# sudo keep-alive background process when the build finishes.
"$(dirname "$0")/scripts/${BUILD_SCRIPT}" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
