#!/bin/bash

# This script provides common customization options for the ISO
#
# Usage: Copy this file to config.sh and make changes there.  Keep this file (default_config.sh) as-is
#   so that subsequent changes can be easily merged from upstream.  Keep all customisations in config.sh

# Ubuntu release codename — only jammy, noble, or resolute are supported.
# See https://wiki.ubuntu.com/DevelopmentCodeNames
export TARGET_UBUNTU_VERSION="noble"

# The Ubuntu Mirror URL. It's better to change for faster download.
# More mirrors see: https://launchpad.net/ubuntu/+archivemirrors
export TARGET_UBUNTU_MIRROR="http://us.archive.ubuntu.com/ubuntu/"

# --- Kernel (HWE metapackages: linux-*-hwe-22.04 | 24.04 | 26.04 only) ---
# See https://wiki.ubuntu.com/Kernel/LTSEnablementStack
#
# HWE suffix is determined by TARGET_UBUNTU_VERSION:
#   jammy    -> 22.04
#   noble    -> 24.04
#   resolute -> 26.04
#
# TARGET_KERNEL_FLAVOR — user choice (also: ./build.sh --kernel=… or -i interactive menu):
#   generic     — linux-generic-hwe-XX.04
#   lowlatency — linux-lowlatency-hwe-XX.04
#
# TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS — apt behaviour for the kernel metapackage only:
#   yes — install recommends (apt-get install -y <metapackage>)
#   no  — skip recommends (apt-get install -y --no-install-recommends <metapackage>)
export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-generic}"
export TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-no}"
export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"

hwe_version_for_release() {
    case "$1" in
        jammy)    echo "22.04" ;;
        noble)    echo "24.04" ;;
        resolute) echo "26.04" ;;
        *)
            echo ""
            ;;
    esac
}

assert_supported_release() {
    case "${TARGET_UBUNTU_VERSION:-}" in
        jammy|noble|resolute)
            return 0
            ;;
        *)
            >&2 echo "TARGET_UBUNTU_VERSION must be jammy, noble, or resolute (got: '${TARGET_UBUNTU_VERSION:-}')."
            return 1
            ;;
    esac
}

set_target_kernel_package_from_flavor() {
    if [[ -n "${TARGET_KERNEL_PACKAGE:-}" ]]; then
        return 0
    fi
    assert_supported_release || exit 1
    case "${TARGET_KERNEL_FLAVOR:-}" in
        generic|lowlatency) ;;
        *)
            >&2 echo "TARGET_KERNEL_FLAVOR must be generic or lowlatency (got: '${TARGET_KERNEL_FLAVOR:-}')."
            exit 1
            ;;
    esac
    local hv
    hv=$(hwe_version_for_release "$TARGET_UBUNTU_VERSION")
    if [[ -z "$hv" ]]; then
        >&2 echo "Internal error: no HWE suffix for TARGET_UBUNTU_VERSION='$TARGET_UBUNTU_VERSION'."
        exit 1
    fi
    case "$TARGET_KERNEL_FLAVOR" in
        generic)
            export TARGET_KERNEL_PACKAGE="linux-generic-hwe-${hv}"
            ;;
        lowlatency)
            export TARGET_KERNEL_PACKAGE="linux-lowlatency-hwe-${hv}"
            ;;
    esac
}

# The file (no extension) of the ISO containing the generated disk image,
# the volume id, and the hostname of the live environment are set from this name.
export TARGET_NAME="ubuntu-from-scratch"

# The text label shown in GRUB for booting into the live environment
export GRUB_LIVEBOOT_LABEL="Try Ubuntu FS without installing"

# The text label shown in GRUB for starting installation
export GRUB_INSTALL_LABEL="Install Ubuntu FS"

# Packages to be removed from the target system after installation completes succesfully
export TARGET_PACKAGE_REMOVE="
    ubiquity \
    casper \
    discover \
    laptop-detect \
    os-prober \
"

# Package customisation function.  Update this function to customize packages
# present on the installed system.
function customize_image() {
    # Vanilla GNOME desktop (no Ubuntu GNOME metapackage / snap pull-ins from that stack)
    apt-get install -y \
        plymouth-themes \
        vanilla-gnome-desktop

    # useful tools
    apt-get install -y \
        clamav-daemon \
        terminator \
        apt-transport-https \
        curl \
        vim \
        nano \
        less

    # purge
    apt-get purge -y \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori
}

# Used to version the configuration.  If breaking changes occur, manual
# updates to this file from the default may be necessary.
export CONFIG_FILE_VERSION="0.7"
