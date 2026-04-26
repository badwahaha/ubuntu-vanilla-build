#!/bin/bash

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# Set in resolve_workspace_paths() during host_main (WSL: avoid /mnt/c for debootstrap).
WORKSPACE_DIR=""
WORKSPACE_CHROOT=""
WORKSPACE_IMAGE=""
# Set to 1 while chroot bind mounts (dev, run, proc, sys, dev/pts) are active (host phase).
CHROOT_MOUNTS_ACTIVE=0
# Prevents duplicate teardown when both a signal handler and EXIT run.
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
DEBUG_SESSION_ID="5d03ce"
DEBUG_LOG_PATH="debug-5d03ce.log"

function agent_debug_log() {
    local run_id="$1"
    local hypothesis_id="$2"
    local location="$3"
    local message="$4"
    local data="$5"
    local ts
    ts="$(date +%s%3N)"
    #region agent log
    printf '{"sessionId":"%s","runId":"%s","hypothesisId":"%s","location":"%s","message":"%s","data":"%s","timestamp":%s}\n' \
        "$DEBUG_SESSION_ID" "$run_id" "$hypothesis_id" "$location" "$message" "$data" "$ts" >> "$DEBUG_LOG_PATH"
    #endregion
}

# ---------------------------------------------------------------------------
# UI helpers: consistent colored output, headings, step counters, prompts.
# Colors auto-disabled if stdout is not a TTY, TERM=dumb, or NO_COLOR is set.
# Set NO_CONFIRM=1 to skip the pre-build confirmation prompt.
# ---------------------------------------------------------------------------
UI_USE_COLOR=0
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    UI_USE_COLOR=1
fi

function _ui_c() {
    if [[ "$UI_USE_COLOR" -eq 1 ]]; then
        printf '\033[%sm' "$1"
    fi
}

function _ui_r() {
    if [[ "$UI_USE_COLOR" -eq 1 ]]; then
        printf '\033[0m'
    fi
}

function ui_banner() {
    local title="$1"
    local bar="=================================================================="
    printf '\n'
    _ui_c '1;36'; printf '%s\n'     "$bar";   _ui_r
    _ui_c '1;36'; printf '  %s\n'   "$title"; _ui_r
    _ui_c '1;36'; printf '%s\n'     "$bar";   _ui_r
    printf '\n'
}

function ui_heading() {
    printf '\n'
    _ui_c '1;34'; printf -- '--- %s ---\n' "$1"; _ui_r
}

function ui_step() {
    local n="$1" total="$2" name="$3"
    printf '\n'
    _ui_c '1;33'; printf '[%d/%d] %s\n' "$n" "$total" "$name"; _ui_r
}

function ui_ok()   { _ui_c '32';   printf '  OK    %s\n' "$1"; _ui_r; }
function ui_warn() { _ui_c '33';   printf '  WARN  %s\n' "$1" >&2; _ui_r; }
function ui_err()  { _ui_c '1;31'; printf '  ERROR %s\n' "$1" >&2; _ui_r; }
function ui_info() { _ui_c '36';   printf '  info  %s\n' "$1"; _ui_r; }

function ui_kv() {
    printf '    %-22s %s\n' "$1" "$2"
}

# ui_confirm "Prompt" [y|n]  — default is "y" if omitted. Returns 0 for yes, 1 for no.
function ui_confirm() {
    local prompt="${1:-Proceed?}"
    local default="${2:-y}"
    local hint yn
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -r -p "  ${prompt} ${hint}: " yn
        yn="${yn,,}"
        [[ -z "$yn" ]] && yn="$default"
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  Please answer y or n." ;;
        esac
    done
}

# Host (outside chroot): prepare tree, debootstrap, run chroot phase, squashfs + ISO
HOST_CMD=(setup_host debootstrap run_chroot build_iso)

# Chroot phase: APT setup, packages, /image layout, cleanup
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

# Run host commands as root: sudo when invoked as a normal user, direct exec when already root.
function host_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

function default_target_package_remove() {
    case "${TARGET_INSTALLER:-calamares}" in
        calamares)
            echo "calamares casper discover laptop-detect os-prober ubiquity-slideshow-ubuntu"
            ;;
        ubiquity)
            echo "ubiquity ubiquity-frontend-gtk ubiquity-ubuntu-artwork ubiquity-slideshow-ubuntu casper discover laptop-detect os-prober"
            ;;
        *)
            >&2 echo "Internal error: default_target_package_remove with TARGET_INSTALLER='${TARGET_INSTALLER:-}'."
            exit 1
            ;;
    esac
}

function set_defaults() {
    export TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}"
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu/}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-}"
    export TARGET_NAME="${TARGET_NAME:-ubuntu}"
    export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Ubuntu without installing}"
}

# TARGET_INSTALLER / TARGET_PACKAGE_REMOVE (after CLI and interactive resolution on the host).
function set_installer_and_manifest_defaults() {
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    case "${TARGET_INSTALLER}" in
        calamares|ubiquity) ;;
        *)
            >&2 echo "TARGET_INSTALLER must be calamares or ubiquity (got: '${TARGET_INSTALLER}')."
            exit 1
            ;;
    esac
    export TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-$(default_target_package_remove)}"
}

function hwe_version_for_release() {
    case "$1" in
        jammy)    echo "22.04" ;;
        noble)    echo "24.04" ;;
        resolute) echo "26.04" ;;
        *)        echo "" ;;
    esac
}

function assert_supported_release() {
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

function set_target_kernel_package_from_flavor() {
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
    hv="$(hwe_version_for_release "$TARGET_UBUNTU_VERSION")"
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

function block_snapd() {
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
Package: snapd
Pin: release *
Pin-Priority: -1
EOF
}

function apt_install_available() {
    local label="$1"
    shift

    local pkg candidate sim_out
    local -a installable=()
    local -a skipped=()
    local -a snapd_blocked=()
    local -a unresolved=()

    for pkg in "$@"; do
        candidate="$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2; exit}')"
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            skipped+=("$pkg")
            continue
        fi

        # Validate installability under the current APT policy (including nosnap.pref).
        if ! sim_out="$(apt-get -s install -y "$pkg" 2>&1)"; then
            unresolved+=("$pkg")
            continue
        fi

        # Extra guard: skip if resolver still plans to install snapd.
        if [[ "$sim_out" == Inst\ snapd* || "$sim_out" == *$'\nInst snapd '* || "$sim_out" == *$'\nInst snapd:'* ]]; then
            snapd_blocked+=("$pkg")
            continue
        fi

        installable+=("$pkg")
    done

    if ((${#skipped[@]})); then
        echo "=====> ${label}: skipping unavailable packages: ${skipped[*]}"
    fi
    if ((${#unresolved[@]})); then
        echo "=====> ${label}: skipping packages with unsatisfied dependencies: ${unresolved[*]}"
    fi
    if ((${#snapd_blocked[@]})); then
        echo "=====> ${label}: skipping packages that would pull snapd: ${snapd_blocked[*]}"
    fi
    if ((${#installable[@]})); then
        echo "=====> ${label}: installing ${installable[*]}"
        apt-get install -y "${installable[@]}"
    else
        echo "=====> ${label}: no installable packages found"
    fi
}

function customize_image() {
    block_snapd

    case "${TARGET_DESKTOP:-gnome}" in
        gnome)
            echo "=====> desktop flavor: gnome"
            if [[ "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" == "1" ]]; then
                echo "=====> gnome package recommends: enabled"
                apt-get install -y vanilla-gnome-desktop gnome-console
            else
                echo "=====> gnome package recommends: disabled (default lightweight mode)"
                apt-get install -y --no-install-recommends vanilla-gnome-desktop gnome-console
            fi
            ;;
        xfce)
            echo "=====> desktop flavor: xfce"
            # Xubuntu-equivalent package set, minus the xubuntu-* branding
            # (no xubuntu-default-settings, xubuntu-artwork, xubuntu-wallpapers*,
            # xubuntu-icon-theme, xubuntu-docs, xubuntu-community-*).
           apt-get install -y \
                xfce4 \
                xfce4-goodies \
                xfce4-terminal \
                xfce4-notifyd \
                xfce4-power-manager \
                xfce4-pulseaudio-plugin \
                xfce4-screensaver \
                xfce4-taskmanager \
                xfce4-indicator-plugin \
                xfce4-whiskermenu-plugin \
                thunar-archive-plugin \
                thunar-media-tags-plugin \
                thunar-volman \
                tumbler \
                gvfs \
                gvfs-backends \
                gvfs-fuse \
                catfish \
                menulibre \
                mugshot \
                gigolo \
                galculator \
                xarchiver \
                blueman \
                pulseaudio \
                pavucontrol \
                synaptic \
                xdg-user-dirs \
                xdg-user-dirs-gtk \
                fonts-ubuntu \
                fonts-noto-core \
                hunspell-en-us \
                onboard \
                xorg \
                lightdm \
                slick-greeter \
                labwc
            ;;
        *)
            >&2 echo "TARGET_DESKTOP must be gnome or xfce (got: '${TARGET_DESKTOP:-}')."
            exit 1
            ;;
    esac
    apt-get install -y plymouth plymouth-label plymouth-theme-ubuntu-text

    apt-get install -y curl apt-transport-https ca-certificates squashfs-tools

    install -d /usr/share/keyrings /etc/apt/sources.list.d
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

    apt-get update
    apt-get install -y brave-browser

    apt-get install -y \
        git \
        vim \
        nano \
        wget \
        less

    apt-get install -y flatpak
    flatpak remote-add --if-not-exists --system flathub \
        https://flathub.org/repo/flathub.flatpakrepo

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get install -y \
            gnome-software \
            gnome-software-plugin-flatpak
    fi

    apt-get purge -y --ignore-missing \
        transmission-gtk \
        transmission-common \
        aisleriot \
        hitori

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get purge -y --ignore-missing \
            gnome-mahjongg \
            gnome-mines \
            gnome-sudoku
    fi

    apt-get purge -y --ignore-missing \
        ubiquity-slideshow-ubuntu \
        calamares-slideshow-ubuntu \
        || true
}

function check_settings() {
    assert_supported_release || exit 1
    case "${TARGET_DESKTOP:-}" in
        gnome|xfce)
            ;;
        *)
            >&2 echo "TARGET_DESKTOP must be gnome or xfce (got: '${TARGET_DESKTOP:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" in
        0|1)
            ;;
        *)
            >&2 echo "TARGET_GNOME_INSTALL_RECOMMENDS must be 0 or 1 (got: '${TARGET_GNOME_INSTALL_RECOMMENDS:-}')."
            exit 1
            ;;
    esac
}

function host_help() {
    if [ -z "${1+x}" ]; then
        echo "This script builds a bootable Ubuntu ISO image."
        echo
    else
        echo "$1"
        echo
    fi

    echo "Supported commands: ${HOST_CMD[*]}"
    echo
    echo "Options:"
    echo "  --release=jammy|noble|resolute          Target Ubuntu release (omit to be prompted on a TTY)"
    echo "  --mirror=URL                            Ubuntu package mirror"
    echo "  UBUNTU_VANILLA_WORKSPACE=DIR             Parent directory for build workspace (optional; auto on WSL /mnt/c)"
    echo "  TARGET_INSTALLER=calamares|ubiquity       Live installer (optional; default calamares)"
    echo "  TARGET_DESKTOP=gnome|xfce                Desktop flavor (optional; default gnome)"
    echo "  TARGET_GNOME_INSTALL_RECOMMENDS=0|1       GNOME install with recommends (optional; default 0)"
    echo "  --kernel=generic|lowlatency             Kernel type to install"
    echo "  --installer=calamares|ubiquity           Calamares (default), or Ubiquity (jammy/22.04 only)"
    echo "  --desktop=gnome|xfce                     Desktop flavor to install"
    echo "  -i, --interactive                       Ask for release, installer, kernel, and desktop on a TTY"
    echo
    echo "Syntax: $0 [options] [start_cmd] [-] [end_cmd]"
    echo "  Run from start_cmd to end_cmd"
    echo "  If no start_cmd/end_cmd are given, all host steps run (same as '-')"
    echo "  If start_cmd is given without '-', only that command runs"
    echo "  If end_cmd is omitted (with a start_cmd), stop after the selected start_cmd"
    echo "  Use '-' by itself to run all commands explicitly"
    echo
    exit 0
}

function host_find_index() {
    local i
    for ((i=0; i<${#HOST_CMD[*]}; i++)); do
        if [ "${HOST_CMD[i]}" == "$1" ]; then
            index=$i
            return
        fi
    done
    host_help "Command not found: $1"
}

function check_host_user() {
    local ID ID_LIKE

    if [[ ! -r /etc/os-release ]]; then
        >&2 echo "ERROR: /etc/os-release is missing or unreadable."
        >&2 echo "This script must be run on Ubuntu (or an Ubuntu-based distribution) or on Debian (or a Debian-based distribution)."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release

    if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
        return 0
    fi

    if [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
        if [[ "${ID:-}" == "debian" ]] && ! dpkg -s ubuntu-archive-keyring &>/dev/null; then
            >&2 echo "ERROR: On Debian, install the Ubuntu archive keyring before building (required for debootstrap from Ubuntu mirrors):"
            >&2 echo "  sudo apt install ubuntu-archive-keyring"
            exit 1
        fi
        return 0
    fi

    >&2 echo "ERROR: Unsupported host OS (ID='${ID:-unknown}', ID_LIKE='${ID_LIKE:-}')."
    >&2 echo "Run this script only on Ubuntu or an Ubuntu-based system, or on Debian or a Debian-based system."
    exit 1
}

function ensure_workspace_root() {
    host_priv mkdir -p "$WORKSPACE_DIR"
}

function clean_workspace() {
    if [[ -e "$WORKSPACE_DIR" ]]; then
        echo "=====> removing workspace ..."
        host_priv rm -rf "$WORKSPACE_DIR"
    fi
}

function chroot_enter_setup() {
    host_priv mount --bind /dev "$WORKSPACE_CHROOT/dev"
    host_priv mount --bind /run "$WORKSPACE_CHROOT/run"
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t proc /proc
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t sysfs /sys
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t devpts /dev/pts
    CHROOT_MOUNTS_ACTIVE=1
}

function chroot_exit_teardown() {
    CHROOT_MOUNTS_ACTIVE=0
    [[ -z "${WORKSPACE_CHROOT:-}" ]] && return 0
    # Unmount from the host so we still unwind if chroot is unusable; order: inner mounts, then bind mounts.
    host_priv umount -l "$WORKSPACE_CHROOT/dev/pts" 2>/dev/null || true
    host_priv umount -l "$WORKSPACE_CHROOT/proc" 2>/dev/null || true
    host_priv umount -l "$WORKSPACE_CHROOT/sys" 2>/dev/null || true
    host_priv umount -l "$WORKSPACE_CHROOT/run" 2>/dev/null || true
    host_priv umount -l "$WORKSPACE_CHROOT/dev" 2>/dev/null || true
}

# On failed or interrupted host build: drop chroot mounts (if any) and remove the workspace tree so leftover
# mounts do not require a reboot to clear.
function host_abort_cleanup() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        return 0
    fi
    HOST_ABORT_CLEANUP_DONE=1
    echo "=====> unmounting chroot bind mounts and removing workspace ..." >&2
    chroot_exit_teardown || true
    if [[ -n "${WORKSPACE_DIR:-}" ]]; then
        clean_workspace || true
    fi
}

function host_build_exit_trap() {
    local _st=$?
    if [[ "$_st" -ne 0 ]] && [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 0 ]]; then
        host_abort_cleanup
    fi
    exit "$_st"
}

function host_build_int_trap() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit 130
    fi
    host_abort_cleanup
    exit 130
}

function host_build_term_trap() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit 143
    fi
    host_abort_cleanup
    exit 143
}

function setup_host() {
    echo "=====> running setup_host ..."
    host_priv apt update
    host_priv apt install -y debootstrap squashfs-tools xorriso
    clean_workspace
    ensure_workspace_root
    host_priv mkdir -p "$WORKSPACE_CHROOT"
}

function debootstrap() {
    echo "=====> running debootstrap ... this will take a few minutes ..."
    host_priv debootstrap --arch=amd64 --variant=minbase "$TARGET_UBUNTU_VERSION" "$WORKSPACE_CHROOT" "$TARGET_UBUNTU_MIRROR"
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    chroot_enter_setup

    host_priv cp "$SCRIPT_DIR/build.sh" "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"
    if [[ -d "$SCRIPT_DIR/calamares" ]]; then
        host_priv cp -a "$SCRIPT_DIR/calamares" "$WORKSPACE_CHROOT/root/calamares-config"
    fi

    host_priv chroot "$WORKSPACE_CHROOT" /usr/bin/env \
        DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-readline}" \
        TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION}" \
        TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
        TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" \
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
        TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}" \
        TARGET_GNOME_INSTALL_RECOMMENDS="${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" \
        TARGET_NAME="${TARGET_NAME}" \
        GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL}" \
        TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}" \
        TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE}" \
        /root/build.sh --chroot-internal -

    host_priv rm -f "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"

    chroot_exit_teardown
}

function write_iso_hashes() {
    local iso_path="$SCRIPT_DIR/$TARGET_NAME.iso"
    local sha1_path="$iso_path.sha1"
    local sha256_path="$iso_path.sha256"

    echo "=====> writing SHA-1 and SHA-256 ..."
    (
        cd "$SCRIPT_DIR"
        sha1sum "$TARGET_NAME.iso" > "$(basename "$sha1_path")"
        sha256sum "$TARGET_NAME.iso" > "$(basename "$sha256_path")"
    )
}

function build_iso() {
    echo "=====> running build_iso ..."

    ensure_workspace_root
    host_priv rm -rf "$WORKSPACE_IMAGE"
    host_priv mv "$WORKSPACE_CHROOT/image" "$WORKSPACE_IMAGE"

    host_priv mksquashfs "$WORKSPACE_CHROOT" "$WORKSPACE_IMAGE/casper/filesystem.squashfs" \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile" \
        -e "image"

    printf "%s" "$(host_priv du -sx --block-size=1 "$WORKSPACE_CHROOT" | cut -f1)" | host_priv tee "$WORKSPACE_IMAGE/casper/filesystem.size" >/dev/null

    local boot_hybrid_img="$WORKSPACE_CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img"
    if [[ ! -f "$boot_hybrid_img" ]]; then
        >&2 echo "Missing $boot_hybrid_img (grub-pc-bin not installed in chroot?). Cannot build hybrid BIOS/UEFI ISO."
        exit 1
    fi
    if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/bios.img" ]]; then
        >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/bios.img (build_image step did not produce it). Aborting."
        exit 1
    fi
    if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/efiboot.img" ]]; then
        >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/efiboot.img (build_image step did not produce it). Aborting."
        exit 1
    fi

    # ISO 9660 volume id: A-Z 0-9 _ only, max 32 chars. Normalize so xorriso doesn't warn.
    local iso_volid
    iso_volid="$(printf '%s' "$TARGET_NAME" \
        | tr '[:lower:]' '[:upper:]' \
        | tr -c 'A-Z0-9_' '_' \
        | cut -c1-32)"

    pushd "$WORKSPACE_IMAGE" >/dev/null

    # Hybrid BIOS + UEFI El Torito layout (matches what Ubuntu/Debian ship today):
    #   * Legacy/BIOS boot:  -b boot/grub/bios.img   (must exist inside the ISO tree)
    #     - bios.img is "cdboot.img + core.img" produced by build_image()
    #     - --grub2-boot-info patches GRUB's offsets so it finds its core inside the ISO
    #     - --grub2-mbr embeds boot_hybrid.img as the protective MBR (BIOS hybrid boot)
    #   * UEFI boot:         efiboot.img is appended as GPT partition 2 (EFI System
    #     Partition GUID, mixed-endian = 28732ac11ff8d211ba4b00a0c93ec93b), and the
    #     UEFI alt-boot entry points at that appended partition via the
    #     `--interval:appended_partition_2:all::` pseudo-path. UEFI firmware mounts the
    #     ESP partition directly, so the file does NOT also need to live in the ISO9660
    #     tree (we keep it there too for tooling that still looks for /boot/grub/efiboot.img).
    # EFI System Partition GUID (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) in the
    # on-disk mixed-endian byte order that xorriso's -append_partition expects.
    local esp_type_guid="28732ac11ff8d211ba4b00a0c93ec93b"
    # Microsoft Basic Data Partition GUID (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
    # in mixed-endian, used as the ISO MBR partition type so the ISO9660 area is
    # visible as a normal data partition when the stick is inspected.
    local iso_mbr_type_guid="a2a0d0ebe5b9334487c068b6b72699c7"

    host_priv xorriso \
        -as mkisofs \
        -r -V "$iso_volid" \
        -J -joliet-long \
        -l \
        -iso-level 3 \
        -full-iso9660-filenames \
        -o "$SCRIPT_DIR/$TARGET_NAME.iso" \
        \
        --grub2-mbr "$boot_hybrid_img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 "$esp_type_guid" boot/grub/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type "$iso_mbr_type_guid" \
        \
        -c boot.catalog \
        -b boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:all::' \
            -no-emul-boot \
        \
        .

    popd >/dev/null

    write_iso_hashes
    clean_workspace
}

function interactive_release_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --release=jammy|noble|resolute."
        exit 1
    fi

    ui_heading "Ubuntu release"
    cat <<'EOF'
    1) jammy     Ubuntu 22.04 LTS
    2) noble     Ubuntu 24.04 LTS
    3) resolute  Ubuntu 26.04 LTS
EOF

    local choice
    while true; do
        read -r -p "  Release [1/2/3]: " choice
        case "${choice,,}" in
            1|jammy)    export TARGET_UBUNTU_VERSION="jammy";    break ;;
            2|noble)    export TARGET_UBUNTU_VERSION="noble";    break ;;
            3|resolute) export TARGET_UBUNTU_VERSION="resolute"; break ;;
            "")  ui_warn "Please choose 1, 2, or 3." ;;
            *)   ui_warn "Invalid selection: '$choice'. Please choose 1, 2, or 3." ;;
        esac
    done
    ui_ok "TARGET_UBUNTU_VERSION=$TARGET_UBUNTU_VERSION"
}

function resolve_release_choice() {
    if [[ -n "${TARGET_UBUNTU_VERSION:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_release_pick
        return 0
    fi

    >&2 echo "TARGET_UBUNTU_VERSION is not set. Use --release=jammy|noble|resolute for non-interactive runs."
    exit 1
}

function interactive_kernel_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --kernel=generic|lowlatency."
        exit 1
    fi

    local hv=""
    hv="$(hwe_version_for_release "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Kernel flavor${hv:+ (HWE stream for Ubuntu ${hv})}"
    printf '    1) generic     Recommended for most systems%s\n' \
        "${hv:+  (linux-generic-hwe-${hv})}"
    printf '    2) lowlatency  Better for audio / low-latency workloads%s\n' \
        "${hv:+  (linux-lowlatency-hwe-${hv})}"

    local choice
    while true; do
        read -r -p "  Kernel [1/2]: " choice
        case "${choice,,}" in
            1|g|generic)    export TARGET_KERNEL_FLAVOR="generic";    break ;;
            2|l|lowlatency) export TARGET_KERNEL_FLAVOR="lowlatency"; break ;;
            "")  ui_warn "Please choose 1 or 2." ;;
            *)   ui_warn "Invalid selection: '$choice'. Please choose 1 or 2." ;;
        esac
    done
    ui_ok "TARGET_KERNEL_FLAVOR=$TARGET_KERNEL_FLAVOR"
}

function resolve_kernel_choice() {
    if [[ -n "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_kernel_pick
        return 0
    fi

    >&2 echo "TARGET_KERNEL_FLAVOR is not set. Use --kernel=generic|lowlatency for non-interactive runs."
    exit 1
}

function interactive_desktop_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --desktop=gnome|xfce."
        exit 1
    fi

    ui_heading "Desktop environment"
    echo "    1) GNOME    Default. vanilla-gnome-desktop (recommends asked next)"
    echo "    2) XFCE     Lighter. xfce4 + xfce4-goodies + lightdm + slick-greeter"

    local choice
    while true; do
        read -r -p "  Desktop [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|g|gnome)   export TARGET_DESKTOP="gnome";   break ;;
            2|x|xfce)       export TARGET_DESKTOP="xfce";    break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
}

function resolve_desktop_choice() {
    if [[ -n "${TARGET_DESKTOP:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_desktop_pick
        return 0
    fi

    export TARGET_DESKTOP=gnome
}

function interactive_gnome_recommends_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use TARGET_GNOME_INSTALL_RECOMMENDS=0|1."
        exit 1
    fi

    ui_heading "GNOME extra recommends"
    echo "    y) apt install vanilla-gnome-desktop     (fuller GNOME experience)"
    echo "    n) apt install --no-install-recommends   (lighter; default)"
    if ui_confirm "Include recommended packages?" n; then
        export TARGET_GNOME_INSTALL_RECOMMENDS="1"
    else
        export TARGET_GNOME_INSTALL_RECOMMENDS="0"
    fi
    ui_ok "TARGET_GNOME_INSTALL_RECOMMENDS=$TARGET_GNOME_INSTALL_RECOMMENDS"
}

function resolve_gnome_recommends_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "gnome" ]]; then
        export TARGET_GNOME_INSTALL_RECOMMENDS=0
        return 0
    fi

    if [[ -n "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_gnome_recommends_pick
        return 0
    fi

    export TARGET_GNOME_INSTALL_RECOMMENDS=0
}

function interactive_installer_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --installer=calamares|ubiquity."
        exit 1
    fi

    ui_heading "Live installer"
    echo "    1) Calamares  Default. Project config in scripts/calamares (all releases)"
    echo "    2) Ubiquity   Classic Ubuntu installer (supported only on jammy / 22.04 LTS)"

    local choice
    while true; do
        read -r -p "  Installer [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|c|calamares) export TARGET_INSTALLER="calamares"; break ;;
            2|u|ubiquity)
                if [[ "${TARGET_UBUNTU_VERSION:-}" != "jammy" ]]; then
                    ui_warn "Ubiquity is supported only on Ubuntu 22.04 LTS (jammy)."
                    ui_warn "Current release: '${TARGET_UBUNTU_VERSION:-unknown}'. Choose 1 (Calamares),"
                    ui_warn "or restart with --release=jammy if you need Ubiquity."
                    continue
                fi
                export TARGET_INSTALLER="ubiquity"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_INSTALLER=$TARGET_INSTALLER"
}

# Ubiquity is only validated for jammy; Calamares is used for noble and resolute.
function validate_ubiquity_jammy_only() {
    if [[ "${TARGET_INSTALLER:-}" != "ubiquity" ]]; then
        return 0
    fi
    if [[ "${TARGET_UBUNTU_VERSION:-}" == "jammy" ]]; then
        return 0
    fi
    echo >&2 "ERROR: Ubiquity is supported only on Ubuntu 22.04 LTS (jammy)."
    echo >&2 "       This build targets '${TARGET_UBUNTU_VERSION:-unknown}'. Use Calamares instead (e.g. --installer=calamares)."
    exit 1
}

function resolve_installer_choice() {
    if [[ -n "${TARGET_INSTALLER:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_installer_pick
        return 0
    fi

    export TARGET_INSTALLER=calamares
}

# debootstrap extracts .deb archives with tar; DrvFs/9p under WSL (/mnt/c, etc.) breaks that. Use ext4 (e.g. ~/.cache/...) instead.
function resolve_workspace_paths() {
    local repo_root
    repo_root="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
    local fs_type ft_lower
    fs_type="$(df -T "$repo_root" 2>/dev/null | awk 'NR==2 {print $2}')"
    ft_lower="$(printf '%s' "$fs_type" | tr '[:upper:]' '[:lower:]')"

    if [[ -n "${UBUNTU_VANILLA_WORKSPACE:-}" ]]; then
        WORKSPACE_DIR="${UBUNTU_VANILLA_WORKSPACE%/}/workspace"
        echo "=====> Workspace (UBUNTU_VANILLA_WORKSPACE): $WORKSPACE_DIR" >&2
    elif [[ "$repo_root" == /mnt/* ]] || [[ "$repo_root" == /media/* ]] || \
         [[ "$fs_type" == 9p ]] || [[ "$ft_lower" == drvfs ]]; then
        local _cache="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}"
        WORKSPACE_DIR="$_cache/ubuntu-vanilla-build/workspace"
        echo "=====> Windows/WSL filesystem (${fs_type:-unknown}) at $repo_root — debootstrap cannot unpack reliably there." >&2
        echo "=====> Using Linux-native workspace: $WORKSPACE_DIR" >&2
    else
        WORKSPACE_DIR="$repo_root/workspace"
    fi
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/image"

    if [[ "${TMPDIR:-}" == /mnt/* ]] || [[ "${TMPDIR:-}" == /media/* ]]; then
        echo "=====> TMPDIR is on a Windows mount (${TMPDIR:-}); using /tmp for extraction." >&2
        export TMPDIR=/tmp
    fi
}

function print_build_summary() {
    local hv=""
    hv="$(hwe_version_for_release "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Build configuration"
    ui_kv "Ubuntu release"  "${TARGET_UBUNTU_VERSION:-?}${hv:+  (Ubuntu ${hv} LTS)}"
    ui_kv "Kernel"          "${TARGET_KERNEL_FLAVOR:-?}${TARGET_KERNEL_PACKAGE:+  [${TARGET_KERNEL_PACKAGE}]}"
    ui_kv "Desktop"         "${TARGET_DESKTOP:-?}"
    case "${TARGET_DESKTOP:-}" in
        gnome)  ui_kv "  with Recommends" "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" ;;
    esac
    ui_kv "Installer"       "${TARGET_INSTALLER:-?}"
    ui_kv "Target name"     "${TARGET_NAME:-?}"
    ui_kv "Mirror"          "${TARGET_UBUNTU_MIRROR:-?}"
    ui_kv "Workspace"       "${WORKSPACE_DIR:-?}"
    ui_kv "Output ISO"      "${SCRIPT_DIR}/${TARGET_NAME:-ubuntu}.iso"
    echo
}

function print_build_result() {
    local iso_path="${SCRIPT_DIR}/${TARGET_NAME:-ubuntu}.iso"
    if [[ ! -f "$iso_path" ]]; then
        ui_heading "Build finished"
        ui_info "No ISO produced at $iso_path (this is expected for partial runs)."
        return 0
    fi
    local size=""
    size="$(du -h --apparent-size "$iso_path" 2>/dev/null | awk '{print $1}')"

    ui_heading "Build complete"
    ui_kv "ISO"    "$iso_path"
    ui_kv "Size"   "${size:-unknown}"
    if [[ -f "$iso_path.sha1" ]]; then
        ui_kv "SHA1"   "$(awk '{print $1}' "$iso_path.sha1")"
    fi
    if [[ -f "$iso_path.sha256" ]]; then
        ui_kv "SHA256" "$(awk '{print $1}' "$iso_path.sha256")"
    fi
    echo
    echo "  Next steps:"
    echo "    * Write to USB on Linux (replace /dev/sdX with your stick's device):"
    echo "        sudo dd if=\"$iso_path\" of=/dev/sdX bs=4M status=progress conv=fsync"
    echo "    * Write to USB on Windows: Rufus or balenaEtcher in ISO/DD image mode"
    echo "    * Test-boot in QEMU (UEFI):"
    echo "        qemu-system-x86_64 -m 4G -enable-kvm -cdrom \"$iso_path\" \\"
    echo "            -bios /usr/share/OVMF/OVMF_CODE.fd"
    echo
}

function host_main() {
    local interactive=0
    local cli_kernel=""
    local cli_release=""
    local cli_mirror=""
    local cli_installer=""
    local cli_desktop=""
    local args=()

    set_defaults

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel=generic|--kernel=lowlatency)
                cli_kernel="${1#--kernel=}"
                shift
                ;;
            --kernel)
                cli_kernel="$2"
                shift 2
                ;;
            --release=jammy|--release=noble|--release=resolute)
                cli_release="${1#--release=}"
                shift
                ;;
            --release)
                cli_release="$2"
                shift 2
                ;;
            --mirror=*)
                cli_mirror="${1#--mirror=}"
                shift
                ;;
            --mirror)
                cli_mirror="$2"
                shift 2
                ;;
            -i|--interactive)
                interactive=1
                shift
                ;;
            --installer=calamares|--installer=ubiquity)
                cli_installer="${1#--installer=}"
                shift
                ;;
            --installer)
                cli_installer="$2"
                shift 2
                ;;
            --desktop=gnome|--desktop=xfce)
                cli_desktop="${1#--desktop=}"
                shift
                ;;
            --desktop)
                cli_desktop="$2"
                shift 2
                ;;
            -h|--help)
                host_help
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${args[@]}"

    cd "$SCRIPT_DIR"
    resolve_workspace_paths

    ui_banner "Ubuntu Vanilla ISO Builder"
    ui_kv "Script"     "$0"
    ui_kv "Workspace"  "$WORKSPACE_DIR"
    ui_kv "Started at" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    HOST_ABORT_CLEANUP_DONE=0
    CHROOT_MOUNTS_ACTIVE=0
    trap host_build_exit_trap EXIT
    trap host_build_int_trap INT
    trap host_build_term_trap TERM

    if [[ -n "$cli_release" ]]; then
        export TARGET_UBUNTU_VERSION="$cli_release"
    fi
    if [[ -n "$cli_mirror" ]]; then
        export TARGET_UBUNTU_MIRROR="$cli_mirror"
    fi
    if [[ -n "$cli_kernel" ]]; then
        export TARGET_KERNEL_FLAVOR="$cli_kernel"
    fi
    if [[ -n "$cli_installer" ]]; then
        export TARGET_INSTALLER="$cli_installer"
    fi
    if [[ -n "$cli_desktop" ]]; then
        export TARGET_DESKTOP="$cli_desktop"
    fi

    if [[ "$interactive" -eq 1 || -z "${TARGET_UBUNTU_VERSION:-}" ]]; then
        resolve_release_choice
    fi

    if [[ "$interactive" -eq 1 || -z "${TARGET_INSTALLER:-}" ]]; then
        resolve_installer_choice
    fi
    set_installer_and_manifest_defaults

    validate_ubiquity_jammy_only

    if [[ "$interactive" -eq 1 || -z "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        resolve_kernel_choice
    fi
    if [[ "$interactive" -eq 1 || -z "${TARGET_DESKTOP:-}" ]]; then
        resolve_desktop_choice
    fi
    if [[ "$interactive" -eq 1 || -z "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        resolve_gnome_recommends_choice
    fi

    check_settings
    set_target_kernel_package_from_flavor
    check_host_user

    # With no [start_cmd] [-] [end_cmd], run the full host pipeline (same as '-').
    if [[ $# == 0 ]]; then
        set -- "-"
    fi

    if [[ $# > 3 ]]; then
        host_help
    fi

    local dash_flag=false
    local start_index=0
    local end_index=${#HOST_CMD[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        host_find_index "$ii"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi

    print_build_summary
    ui_info "Phases to run: ${HOST_CMD[*]:$start_index:$((end_index - start_index))}"
    echo
    if [[ -t 0 ]] && [[ "${NO_CONFIRM:-0}" != "1" ]]; then
        if ! ui_confirm "Start build now?" y; then
            echo
            ui_info "Build cancelled by user. No changes were made."
            exit 0
        fi
    fi

    local total=$((end_index - start_index))
    local i
    for ((i=start_index; i<end_index; i++)); do
        ui_step "$((i - start_index + 1))" "$total" "${HOST_CMD[i]}"
        "${HOST_CMD[i]}"
    done

    print_build_result
}

function chroot_help() {
    if [ -z "${1+x}" ]; then
        echo "Chroot phase: build the root filesystem and the live image layout under /image."
        echo
    else
        echo "$1"
        echo
    fi
    echo "Supported commands: ${CHROOT_CMD[*]}"
    echo
    echo "Syntax: $0 --chroot-internal [start_cmd] [-] [end_cmd]"
    echo
    exit 0
}

function chroot_find_index() {
    local i
    for ((i=0; i<${#CHROOT_CMD[*]}; i++)); do
        if [ "${CHROOT_CMD[i]}" == "$1" ]; then
            index=$i
            return
        fi
    done
    chroot_help "Command not found: $1"
}

function check_chroot_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "The chroot phase must run as root."
        exit 1
    fi

    export HOME=/root
    export LC_ALL=C
}

function chroot_prepare() {
    echo "=====> running chroot_prepare ..."

    cat <<EOF > /etc/apt/sources.list
deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
EOF

    echo "$TARGET_NAME" > /etc/hostname

    apt-get update

    block_snapd

    apt-get install -y libterm-readline-gnu-perl systemd-sysv

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    ln -s /bin/true /sbin/initctl
}

# Full Calamares layout from scripts/calamares (settings.conf + modules + curated i18n).
# Only the calamares binary package is installed — no calamares-settings-* metapackages.
function apply_calamares_custom_config() {
    echo "=====> installing Calamares configuration from scripts/calamares ..."
    if [[ ! -d /root/calamares-config ]] || [[ ! -f /root/calamares-config/settings.conf ]]; then
        >&2 echo "Internal error: scripts/calamares must include settings.conf (host did not copy scripts/calamares into the chroot)."
        exit 1
    fi
    install -d /etc/calamares/modules
    cp -a /root/calamares-config/settings.conf /etc/calamares/settings.conf
    cp -a /root/calamares-config/modules/. /etc/calamares/modules/

    if [[ -f /root/calamares-config/i18n/SUPPORTED ]]; then
        install -d /usr/share/i18n
        if [[ -f /usr/share/i18n/SUPPORTED ]]; then
            cp -a /usr/share/i18n/SUPPORTED /usr/share/i18n/SUPPORTED.stock-ubuntu-vanilla-backup
        fi
        cp /root/calamares-config/i18n/SUPPORTED /usr/share/i18n/SUPPORTED
    fi

    # Render the Ubuntu branding template with the correct release version so the installer
    # shows "Ubuntu 24.04 LTS" / "Ubuntu 26.04 LTS" instead of the stock Calamares default
    # ("Fancy GNU/Linux ..."). Matches calamares-settings-ubuntu's per-flavor branding approach.
    local ubuntu_version
    ubuntu_version="$(hwe_version_for_release "$TARGET_UBUNTU_VERSION")"
    if [[ -z "$ubuntu_version" ]]; then
        >&2 echo "Internal error: no Ubuntu marketing version for TARGET_UBUNTU_VERSION='$TARGET_UBUNTU_VERSION'."
        exit 1
    fi
    if [[ ! -f /root/calamares-config/branding/ubuntu/branding.desc ]]; then
        >&2 echo "Internal error: scripts/calamares/branding/ubuntu/branding.desc is missing."
        exit 1
    fi
    install -d /etc/calamares/branding/ubuntu
    # Copy all branding assets (QML slideshow, images); branding.desc is templated next.
    cp -a /root/calamares-config/branding/ubuntu/. /etc/calamares/branding/ubuntu/
    sed -e "s|@VERSION@|${ubuntu_version}|g" \
        -e "s|@CODENAME@|${TARGET_UBUNTU_VERSION}|g" \
        /root/calamares-config/branding/ubuntu/branding.desc \
        > /etc/calamares/branding/ubuntu/branding.desc
}

function install_pkg() {
    echo "=====> running install_pkg ... this will take a while ..."
    echo "=====> kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get -y upgrade

    apt-get install -y \
        sudo \
        ubuntu-standard \
        casper \
        discover \
        laptop-detect \
        os-prober \
        network-manager \
        net-tools \
        locales \
        grub-common \
        grub-gfxpayload-lists \
        grub-pc \
        grub-pc-bin \
        grub2-common \
        grub-efi-amd64-signed \
        shim-signed \
        mtools \
        unzip \
        binutils \
        gparted \
        dosfstools \
        e2fsprogs \
        btrfs-progs \
        xfsprogs \
        ntfs-3g \
        parted

    echo "=====> installing kernel metapackage (with Recommends): $TARGET_KERNEL_PACKAGE"
    apt-get install -y "$TARGET_KERNEL_PACKAGE"

    echo "=====> live installer: ${TARGET_INSTALLER}"
    case "${TARGET_INSTALLER}" in
        calamares)
            # Depends only (no Recommends): avoids pulling calamares-settings-* packages; config is 100% scripts/calamares.
            apt-get install -y --no-install-recommends calamares
            apply_calamares_custom_config
            ;;
        ubiquity)
            if [[ "${TARGET_UBUNTU_VERSION}" != "jammy" ]]; then
                >&2 echo "Internal error: Ubiquity is supported only on jammy; got TARGET_UBUNTU_VERSION='${TARGET_UBUNTU_VERSION}'."
                exit 1
            fi
            # No-install-recommends prevents ubiquity-slideshow-ubuntu from being pulled in.
            apt-get install -y --no-install-recommends ubiquity ubiquity-frontend-gtk
            ;;
        *)
            >&2 echo "Internal error: unsupported TARGET_INSTALLER: ${TARGET_INSTALLER:-}"
            exit 1
            ;;
    esac

    customize_image

    apt-get autoremove -y

    dpkg-reconfigure locales

    cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=none
plugins=ifupdown,keyfile
dns=systemd-resolved

[ifupdown]
managed=false
EOF

    dpkg-reconfigure network-manager

    apt-get clean -y
}

function build_image() {
    echo "=====> running build_image ..."

    rm -rf /image
    mkdir -p /image/{casper,boot/grub,install,EFI/boot,EFI/ubuntu}

    pushd /image >/dev/null

    local vmlinuz_src initrd_src
    vmlinuz_src="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
    initrd_src="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)"
    if [[ -z "${vmlinuz_src:-}" || ! -f "$vmlinuz_src" ]]; then
        echo "No /boot/vmlinuz-* file was found. Did the kernel install fail?" >&2
        exit 1
    fi
    if [[ -z "${initrd_src:-}" || ! -f "$initrd_src" ]]; then
        echo "No /boot/initrd.img-* file was found. Did the kernel install fail?" >&2
        exit 1
    fi
    cp "$vmlinuz_src" casper/vmlinuz
    cp "$initrd_src" casper/initrd

    wget --progress=dot https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip -O install/memtest86.zip
    unzip -p install/memtest86.zip memtest64.bin > install/memtest86+.bin
    unzip -p install/memtest86.zip memtest64.efi > install/memtest86+.efi
    rm -f install/memtest86.zip

    touch ubuntu
    cat <<EOF > boot/grub/grub.cfg

search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=30

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper nopersistent quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

grub_platform
if [ "\$grub_platform" = "efi" ]; then
menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI)" {
    linux /install/memtest86+.efi
}
else
menuentry "Test memory with Memtest86+ (BIOS)" {
    linux16 /install/memtest86+.bin
}
fi
EOF

    dpkg-query -W --showformat='${Package} ${Version}\n' | tee casper/filesystem.manifest >/dev/null

    cp -v casper/filesystem.manifest casper/filesystem.manifest-desktop

    local pkg
    for pkg in $TARGET_PACKAGE_REMOVE; do
        sed -i "/$pkg/d" casper/filesystem.manifest-desktop
    done

    cat <<EOF > README.diskdefines
#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    cp /usr/lib/shim/shimx64.efi.signed.previous EFI/boot/bootx64.efi
    cp /usr/lib/shim/mmx64.efi EFI/boot/mmx64.efi
    cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed EFI/boot/grubx64.efi
    cp boot/grub/grub.cfg EFI/ubuntu/grub.cfg

    (
        cd boot/grub
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        mkfs.vfat -F 16 efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/bootx64.efi ::efi/boot/bootx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/mmx64.efi ::efi/boot/mmx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/grubx64.efi ::efi/boot/grubx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/ubuntu/grub.cfg
    )

    grub-mkstandalone \
      --format=i386-pc \
      --output=boot/grub/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=boot/grub/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img boot/grub/core.img > boot/grub/bios.img

    /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'boot/grub/efiboot.img' -e 'boot/grub/bios.img' > md5sum.txt)"

    popd >/dev/null
}

function finish_up() {
    echo "=====> finish_up"

    truncate -s 0 /etc/machine-id

    rm /sbin/initctl
    dpkg-divert --rename --remove /sbin/initctl

    rm -rf /tmp/* ~/.bash_history
}

function chroot_main() {
    shift
    set_defaults
    set_installer_and_manifest_defaults
    export TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}"
    validate_ubiquity_jammy_only
    check_settings
    set_target_kernel_package_from_flavor
    check_chroot_root

    if [[ $# == 0 || $# > 3 ]]; then
        chroot_help
    fi

    local dash_flag=false
    local start_index=0
    local end_index=${#CHROOT_CMD[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        chroot_find_index "$ii"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi

    local i
    for ((i=start_index; i<end_index; i++)); do
        "${CHROOT_CMD[i]}"
    done

    echo "$0 --chroot-internal - Chroot phase done."
}

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main "$@"
else
    host_main "$@"
fi
