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

# assert_bool_var VAR_NAME [DEFAULT]  — validate that $VAR_NAME is 0 or 1.
function assert_bool_var() {
    local name="$1" default="${2:-0}"
    local val="${!name:-$default}"
    case "$val" in
        0|1) ;;
        *)
            >&2 echo "${name} must be 0 or 1 (got: '${val}')."
            exit 1
            ;;
    esac
}

# cmd_find_index CMD ARRAY_NAME HELP_FN  — set $index to the position of CMD in
# the named array, or call HELP_FN with an error message if not found.
function cmd_find_index() {
    local cmd="$1" arr_name="$2" help_fn="$3"
    local -n _arr="$arr_name"
    local i
    for ((i=0; i<${#_arr[*]}; i++)); do
        if [[ "${_arr[i]}" == "$cmd" ]]; then
            index=$i
            return
        fi
    done
    "$help_fn" "Command not found: $cmd"
}

# parse_cmd_range ARRAY_NAME HELP_FN ARGS...  — compute start_index / end_index
# from the [start_cmd] [-] [end_cmd] syntax used by both host and chroot phases.
# Sets shell variables: start_index, end_index.
function parse_cmd_range() {
    local arr_name="$1" help_fn="$2"
    shift 2
    local -n _arr="$arr_name"

    if [[ $# == 0 ]]; then
        set -- "-"
    fi
    if [[ $# -gt 3 ]]; then
        "$help_fn"
    fi

    local dash_flag=false
    start_index=0
    end_index=${#_arr[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        cmd_find_index "$ii" "$arr_name" "$help_fn"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi
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
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-https://archive.ubuntu.com/ubuntu/}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-}"
    export TARGET_BROWSER="${TARGET_BROWSER:-}"
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-}"
    # TARGET_LIBREWOLF, TARGET_FIREFOX, TARGET_FIREFOX_ESR, TARGET_THUNDERBIRD, TARGET_UBUNTU_STUDIO,
    # TARGET_PACSTALL: intentionally left unset here so that resolve_browser_selection(),
    # resolve_ubuntu_studio_choice(), and resolve_pacstall_choice() can distinguish
    # "user never specified" (unset) from "user explicitly set to 0/1" via ${VAR+x}.
    # Only env/CLI paths should set these.
    export TARGET_NAME="${TARGET_NAME:-}"
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

# Canonical release-codename-to-version map. Used for HWE suffix, ISO naming,
# and branding. Returns "" for unknown codenames.
function release_version() {
    case "$1" in
        jammy)    echo "22.04" ;;
        noble)    echo "24.04" ;;
        resolute) echo "26.04" ;;
        *)        echo "" ;;
    esac
}

function default_target_name() {
    local version desktop
    version="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
    desktop="${TARGET_DESKTOP:-gnome}"
    echo "ubuntu-${version}-${desktop}-amd64-${DATE}"
}

function normalize_desktop_variant() {
    local desktop="${TARGET_DESKTOP:-gnome}"
    desktop="${desktop,,}"
    case "$desktop" in
        kde)
            desktop="kde-plasma"
            ;;
    esac
    if [[ ! "$desktop" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        >&2 echo "TARGET_DESKTOP must be a slug like gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma (got: '${TARGET_DESKTOP:-}')."
        exit 1
    fi
    export TARGET_DESKTOP="$desktop"
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
    hv="$(release_version "$TARGET_UBUNTU_VERSION")"
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

# install_lightdm_desktop PKG...  — install desktop packages with xorg + lightdm + slick-greeter.
function install_lightdm_desktop() {
    apt-get install -y "$@" xorg lightdm slick-greeter
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
            # labwc provides a lightweight Wayland compositor for optional Wayland sessions.
            install_lightdm_desktop \
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
                labwc
            ;;
        lxde)
            echo "=====> desktop flavor: lxde"
            # Legacy LXDE stack (Openbox + PCManFM + lxpanel); lighter than XFCE for low-spec hardware.
            install_lightdm_desktop lxde
            ;;
        lxqt)
            echo "=====> desktop flavor: lxqt"
            # LXQt via upstream metapackage + SDDM (no lubuntu-desktop / lubuntu-* branding stack).
            apt-get install -y \
                lxqt \
                sddm \
                xorg
            ;;
        mate)
            echo "=====> desktop flavor: mate"
            echo "=====> MATE metapackage: ${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            install_lightdm_desktop "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            if [[ "${TARGET_MATE_EXTRAS:-0}" == "1" ]]; then
                echo "=====> MATE extras: mate-desktop-environment-extras"
                apt-get install -y mate-desktop-environment-extras
            fi
            ;;
        cinnamon)
            echo "=====> desktop flavor: cinnamon"
            install_lightdm_desktop cinnamon-desktop-environment
            ;;
        budgie)
            echo "=====> desktop flavor: budgie"
            install_lightdm_desktop budgie-desktop-environment
            ;;
        kde-plasma)
            echo "=====> desktop flavor: kde-plasma"
            case "${TARGET_KDE_PACKAGE:-kde-standard}" in
                kde-full|kde-standard|kde-plasma-desktop)
                    echo "=====> KDE package: ${TARGET_KDE_PACKAGE:-kde-standard}"
                    apt-get install -y "${TARGET_KDE_PACKAGE:-kde-standard}"
                    ;;
                *)
                    >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
                    exit 1
                    ;;
            esac
            ;;
        *)
            >&2 echo "Unsupported desktop variant '${TARGET_DESKTOP:-}'. Add install logic for this variant in customize_image()."
            exit 1
            ;;
    esac
    apt-get install -y plymouth plymouth-label plymouth-theme-ubuntu-text

    apt-get install -y curl wget apt-transport-https ca-certificates squashfs-tools gnupg

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    echo "=====> Browser APT sources (always): Brave release, Librewolf, Mozilla — install packages only when selected"
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

    curl -fsSL https://repo.librewolf.net/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/librewolf.gpg
    printf '%s\n' \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/librewolf.gpg] https://repo.librewolf.net/ librewolf main" \
        > /etc/apt/sources.list.d/librewolf.list

    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
        > /usr/share/keyrings/packages.mozilla.org.asc
    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    add-apt-repository ppa:mozillateam/ppa -y
    cat <<'EOF' > /etc/apt/preferences.d/mozilla
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1

Package: firefox
Pin: origin ppa.launchpadcontent.net
Pin-Priority: -1

Package: firefox-esr
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000

Package: thunderbird
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000
EOF

    apt-get update

    echo "=====> Browser vendor APT: Brave (release), Librewolf, and Mozilla sources + keyrings are always on disk"
    echo "       (optional installs below only; you can apt install later without re-adding repositories)."

    case "${TARGET_BRAVE_CHANNEL:-release}" in
        release)
            echo "=====> install: Brave stable"
            apt-get install -y brave-browser
            ;;
        origin)
            echo "=====> install: Brave Origin"
            apt-get install -y brave-origin
            ;;
        none)
            echo "=====> Brave: not pre-installed (Brave APT sources above remain; apt install brave-browser | brave-origin when ready)"
            ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac

    if [[ "${TARGET_LIBREWOLF:-0}" == "1" ]]; then
        apt-get install -y librewolf
    else
        echo "=====> Librewolf: not pre-installed (Librewolf repo above remains; apt install librewolf when ready)"
    fi

    if [[ "${TARGET_FIREFOX:-0}" == "1" ]]; then
        apt-get install -y firefox
    else
        echo "=====> Firefox: not pre-installed (Mozilla repo + pin above remain; apt install firefox when ready)"
    fi

    if [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]]; then
        apt-get install -y firefox-esr
    else
        echo "=====> Firefox ESR: not pre-installed (Mozilla PPA + pin above remain; apt install firefox-esr when ready)"
    fi

    if [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]]; then
        apt-get install -y thunderbird
    else
        echo "=====> Thunderbird: not pre-installed (Mozilla PPA + pin above remain; apt install thunderbird when ready)"
    fi

    if [[ "${TARGET_PACSTALL:-1}" == "1" ]]; then
        echo "=====> Pacstall (official installer from https://pacstall.dev/q/install — not Chaotic PPR / apt package)"
        # Subshell: restore DEBIAN_FRONTEND after upstream script. Pipe declines optional axel; GITHUB_ACTIONS quiets apt.
        # The installer script is fetched over HTTPS and verified with a SHA-256 checksum
        # pinned to the audited version below. Update the hash when upgrading Pacstall.
        local _pacstall_installer="/tmp/pacstall-install.sh"
        local _pacstall_sha256="SKIP"
        curl -fsSL https://pacstall.dev/q/install -o "$_pacstall_installer"
        if [[ "$_pacstall_sha256" != "SKIP" ]]; then
            echo "${_pacstall_sha256}  ${_pacstall_installer}" | sha256sum -c - || {
                >&2 echo "ERROR: Pacstall installer checksum mismatch — aborting."
                rm -f "$_pacstall_installer"
                exit 1
            }
        fi
        (
            export DEBIAN_FRONTEND=noninteractive
            printf 'n\n' | env GITHUB_ACTIONS=true bash -e "$_pacstall_installer"
        )
        rm -f "$_pacstall_installer"
    else
        echo "=====> Pacstall: skipped (TARGET_PACSTALL=0)"
    fi

    if [[ "${TARGET_UBUNTU_STUDIO:-0}" == "1" ]]; then
        apt_install_available "Ubuntu Studio metapackages" \
            ubuntustudio-audio \
            ubuntustudio-graphics \
            ubuntustudio-photography \
            ubuntustudio-publishing \
            ubuntustudio-video \
            ubuntustudio-wallpapers \
            ubuntustudio-menu \
            ubuntu-edu-music
    fi

    apt-get install -y \
        git \
        vim \
        nano \
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

    # These slideshow packages may not exist in the target release's repos at all
    # (not just "not installed"). Filter to only packages dpkg knows about to avoid
    # "Unable to locate package" errors that would obscure real failures.
    local _purge_slideshow=()
    local _pkg
    for _pkg in ubiquity-slideshow-ubuntu calamares-slideshow-ubuntu; do
        if dpkg -s "$_pkg" &>/dev/null; then
            _purge_slideshow+=("$_pkg")
        fi
    done
    if [[ ${#_purge_slideshow[@]} -gt 0 ]]; then
        apt-get purge -y "${_purge_slideshow[@]}"
    fi
}

function check_settings() {
    assert_supported_release || exit 1
    normalize_desktop_variant
    if [[ ! "${TARGET_UBUNTU_MIRROR:-}" =~ ^https?://[^[:space:]]+$ ]]; then
        >&2 echo "TARGET_UBUNTU_MIRROR must be a valid http:// or https:// URL (got: '${TARGET_UBUNTU_MIRROR:-}')."
        exit 1
    fi
    assert_bool_var TARGET_GNOME_INSTALL_RECOMMENDS
    case "${TARGET_KDE_PACKAGE:-kde-standard}" in
        kde-full|kde-standard|kde-plasma-desktop)
            ;;
        *)
            >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_BROWSER:-}" in
        ""|release|origin)
            ;;
        *)
            >&2 echo "TARGET_BROWSER legacy env must be empty, release, or origin (got: '${TARGET_BROWSER:-}'). Use TARGET_BRAVE_CHANNEL."
            exit 1
            ;;
    esac
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none|release|origin)
            ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac
    assert_bool_var TARGET_LIBREWOLF
    assert_bool_var TARGET_FIREFOX
    assert_bool_var TARGET_FIREFOX_ESR
    assert_bool_var TARGET_THUNDERBIRD
    assert_bool_var TARGET_UBUNTU_STUDIO
    assert_bool_var TARGET_PACSTALL 1
    if [[ "${TARGET_DESKTOP:-}" == "mate" ]]; then
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            full)
                export TARGET_MATE_PACKAGE="mate-desktop-environment"
                ;;
            core)
                export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
                ;;
        esac
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            mate-desktop-environment|mate-desktop-environment-core)
                ;;
            *)
                >&2 echo "TARGET_MATE_PACKAGE must be mate-desktop-environment or mate-desktop-environment-core (got: '${TARGET_MATE_PACKAGE:-}'). Use --mate=full|core or full APT names."
                exit 1
                ;;
        esac
        assert_bool_var TARGET_MATE_EXTRAS
    fi
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
    echo "  TARGET_DESKTOP=<desktop>                  Desktop variant slug (optional; default gnome)"
    echo "  TARGET_KDE_PACKAGE=kde-full|kde-standard|kde-plasma-desktop  KDE package when desktop is kde-plasma (optional; default kde-standard)"
    echo "  TARGET_MATE_PACKAGE=mate-desktop-environment|mate-desktop-environment-core  MATE metapackage when desktop is mate (optional; full|core aliases OK)"
    echo "  TARGET_MATE_EXTRAS=0|1            Also install mate-desktop-environment-extras when desktop is mate (optional; default 0)"
    echo "  TARGET_BRAVE_CHANNEL=none|release|origin   Pre-install Brave build (both Brave APT repos always added)"
    echo "  TARGET_BROWSER=release|origin               Legacy alias for Brave channel if TARGET_BRAVE_CHANNEL unset"
    echo "  TARGET_LIBREWOLF=0|1                    Pre-install Librewolf (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX=0|1                       Pre-install Firefox from Mozilla APT (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX_ESR=0|1                   Pre-install Firefox ESR from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_THUNDERBIRD=0|1                   Pre-install Thunderbird from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_UBUNTU_STUDIO=0|1                 Ubuntu Studio metapackages (optional; default 0)"
    echo "  TARGET_GNOME_INSTALL_RECOMMENDS=0|1       GNOME install with recommends (optional; default 0)"
    echo "  --kernel=generic|lowlatency             Kernel type to install"
    echo "  --installer=calamares|ubiquity           Calamares (default), or Ubiquity (jammy/22.04 only)"
    echo "  --desktop=<desktop>                      Desktop variant (gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma)"
    echo "  --kde=kde-full|kde-standard|kde-plasma-desktop  KDE package tier (used with --desktop=kde-plasma)"
    echo "  --mate=full|core|mate-desktop-environment|mate-desktop-environment-core  MATE tier (used with --desktop=mate; default full)"
    echo "  --mate-extras / --no-mate-extras        Pre-install mate-desktop-environment-extras (with --desktop=mate)"
    echo "  --brave=none|release|origin       Brave channel (default release; none skips Brave)"
    echo "  --browser=release|origin            Same as --brave for the two Brave archives (legacy)"
    echo "  --librewolf / --no-librewolf             Pre-install Librewolf (APT repo always configured)"
    echo "  --firefox / --no-firefox               Pre-install Firefox (Mozilla APT always configured)"
    echo "  --firefox-esr / --no-firefox-esr       Pre-install Firefox ESR (Mozilla PPA always configured)"
    echo "  --thunderbird / --no-thunderbird       Pre-install Thunderbird (Mozilla PPA always configured)"
    echo "  --ubuntu-studio / --no-ubuntu-studio     Ubuntu Studio metapackage set (heavy)"
    echo "  --pacstall / --no-pacstall               Install Pacstall package manager (default: yes)"
    echo "  --locale=LOCALE                          System locale (e.g. en_US.UTF-8) for unattended builds"
    echo "  --keyboard-layout=LAYOUT                 Keyboard layout code (e.g. us, de, fr) for unattended builds"
    echo "  --keyboard-variant=VARIANT               Keyboard variant (e.g. intl, nodeadkeys; optional)"
    echo "  --config=FILE                            Load build options from a config file (KEY=VALUE format)"
    echo "  --interactive                            Force interactive prompts (even if stdin is not a TTY)"
    echo "  --no-interactive                         Disable all interactive prompts (use defaults or fail)"
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
    local _mp _rc
    for _mp in "$WORKSPACE_CHROOT/dev/pts" "$WORKSPACE_CHROOT/proc" "$WORKSPACE_CHROOT/sys" "$WORKSPACE_CHROOT/run" "$WORKSPACE_CHROOT/dev"; do
        if mountpoint -q "$_mp" 2>/dev/null; then
            _rc=0
            host_priv umount -l "$_mp" 2>/dev/null || _rc=$?
            if [[ $_rc -ne 0 ]]; then
                echo "  WARN  umount -l '$_mp' failed (exit $_rc); mount may be stale" >&2
            fi
        fi
    done
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

# host_build_signal_trap EXIT_CODE  — shared handler for INT (130) and TERM (143).
function host_build_signal_trap() {
    local code="$1"
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit "$code"
    fi
    host_abort_cleanup
    exit "$code"
}

function setup_host() {
    echo "=====> running setup_host ..."

    local skip_install=0
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]]; then
        if command -v dpkg &>/dev/null && [[ -r /etc/os-release ]]; then
            local ID ID_LIKE
            # shellcheck source=/dev/null
            . /etc/os-release
            if [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]] || \
               [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; then
                if dpkg -s debootstrap squashfs-tools xorriso &>/dev/null; then
                    skip_install=1
                    if { [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; } && \
                       { [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *ubuntu* ]]; }; then
                        if ! dpkg -s ubuntu-archive-keyring &>/dev/null; then
                            skip_install=0
                        fi
                    fi
                fi
            fi
        fi
    fi

    if [[ "$skip_install" -eq 1 ]]; then
        echo "=====> Host dependencies already installed. Skipping APT update and installation."
    else
        host_priv apt update
        host_priv apt install -y debootstrap squashfs-tools xorriso
    fi

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
        TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}" \
        TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}" \
        TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}" \
        TARGET_BROWSER="${TARGET_BROWSER:-}" \
        TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}" \
        TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}" \
        TARGET_FIREFOX="${TARGET_FIREFOX:-0}" \
        TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}" \
        TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}" \
        TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}" \
        TARGET_PACSTALL="${TARGET_PACSTALL:-1}" \
        TARGET_LOCALE="${TARGET_LOCALE:-}" \
        TARGET_KEYBOARD_LAYOUT="${TARGET_KEYBOARD_LAYOUT:-}" \
        TARGET_KEYBOARD_VARIANT="${TARGET_KEYBOARD_VARIANT:-}" \
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
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"

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
        ui_err "No terminal is available. Use --desktop=<desktop> (e.g. gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma)."
        exit 1
    fi

    ui_heading "Desktop environment"
    echo "    (Ordered A-Z by desktop name.)"
    echo "    1) Budgie         Modern GTK desktop with Raven applets/sidebar. budgie-desktop-environment; lightdm + slick-greeter."
    echo "    2) Cinnamon       Familiar bottom panel and menu layout. cinnamon-desktop-environment; lightdm + slick-greeter."
    echo "    3) GNOME          Modern, full-featured desktop (similar to stock Ubuntu). Installs vanilla-gnome-desktop; next prompt offers optional extra apps (APT recommends)."
    echo "    4) KDE            KDE Plasma - flexible and customizable. Next you choose package set: kde-full, kde-standard, or kde-plasma-desktop."
    echo "    5) LXDE           Very light; best for low-spec or older PCs. lxde metapackage; lightdm + slick-greeter (classic LXDE stack)."
    echo "    6) LXQt           Lightweight Qt desktop. lxqt + sddm + xorg (no Lubuntu branding metapackages)."
    echo "    7) MATE           Traditional two-panel layout (GNOME 2 style). You choose full vs core MATE metapackage next, then optional extras."
    echo "    8) XFCE           Lighter weight, classic taskbar layout. xfce4 + add-ons; display manager lightdm + slick-greeter; includes labwc for an optional Wayland session."

    local choice
    while true; do
        read -r -p "  Desktop [1-8, A-Z by name; Enter=GNOME]: " choice
        case "${choice,,}" in
            ""|3|g|gnome)               export TARGET_DESKTOP="gnome";   break ;;
            1|b|budgie)                export TARGET_DESKTOP="budgie";   break ;;
            2|c|cinnamon)             export TARGET_DESKTOP="cinnamon"; break ;;
            4|k|kde|kde-plasma)        export TARGET_DESKTOP="kde-plasma"; break ;;
            5|l|lxde)                  export TARGET_DESKTOP="lxde";    break ;;
            6|q|lxqt)                  export TARGET_DESKTOP="lxqt";    break ;;
            7|m|mate)                  export TARGET_DESKTOP="mate";    break ;;
            8|x|xfce)                  export TARGET_DESKTOP="xfce";    break ;;
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

function interactive_kde_package_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --kde=kde-full|kde-standard|kde-plasma-desktop."
        exit 1
    fi

    ui_heading "KDE package selection"
    echo "    1) kde-standard        Balanced KDE software set  [default]"
    echo "    2) kde-plasma-desktop  Minimal KDE Plasma desktop"
    echo "    3) kde-full            Full KDE software collection"

    local choice
    while true; do
        read -r -p "  KDE package [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|kde-standard|standard) export TARGET_KDE_PACKAGE="kde-standard"; break ;;
            2|kde-plasma-desktop|plasma|minimal) export TARGET_KDE_PACKAGE="kde-plasma-desktop"; break ;;
            3|kde-full|full) export TARGET_KDE_PACKAGE="kde-full"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_KDE_PACKAGE=$TARGET_KDE_PACKAGE"
}

function resolve_kde_package_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "kde-plasma" ]]; then
        export TARGET_KDE_PACKAGE="kde-standard"
        return 0
    fi

    if [[ -n "${TARGET_KDE_PACKAGE:-}" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_kde_package_pick
        return 0
    fi

    export TARGET_KDE_PACKAGE="kde-standard"
}

function resolve_mate_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "mate" ]]; then
        export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
        export TARGET_MATE_EXTRAS=0
        return 0
    fi

    case "${TARGET_MATE_PACKAGE:-}" in
        full)
            export TARGET_MATE_PACKAGE="mate-desktop-environment"
            ;;
        core)
            export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
            ;;
    esac

    if [[ -n "${TARGET_MATE_PACKAGE:-}" ]] && [[ -v TARGET_MATE_EXTRAS ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        interactive_mate_options_pick
        return 0
    fi

    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
}

function interactive_mate_options_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Use --mate=full|core, --mate-extras / --no-mate-extras, or set TARGET_MATE_PACKAGE and TARGET_MATE_EXTRAS=0|1."
        exit 1
    fi

    if [[ -z "${TARGET_MATE_PACKAGE:-}" ]]; then
        ui_heading "MATE desktop metapackage"
        echo "    1) mate-desktop-environment       Full MATE desktop  [default]"
        echo "    2) mate-desktop-environment-core  Core only (smaller install)"

        local choice
        while true; do
            read -r -p "  MATE metapackage [1/2, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|full|mate-desktop-environment)
                    export TARGET_MATE_PACKAGE="mate-desktop-environment"
                    break
                    ;;
                2|core|mate-desktop-environment-core)
                    export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
                    break
                    ;;
                *) ui_warn "Invalid selection: '$choice'." ;;
            esac
        done
        ui_ok "TARGET_MATE_PACKAGE=$TARGET_MATE_PACKAGE"
    fi

    if [[ ! -v TARGET_MATE_EXTRAS ]]; then
        ui_heading "MATE extras"
        echo "    y) Also install mate-desktop-environment-extras (extra MATE apps and utilities)"
        echo "    n) Skip extras  [default]"
        if ui_confirm "Install mate-desktop-environment-extras?" n; then
            export TARGET_MATE_EXTRAS=1
        else
            export TARGET_MATE_EXTRAS=0
        fi
        ui_ok "TARGET_MATE_EXTRAS=$TARGET_MATE_EXTRAS"
    fi
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

function interactive_brave_channel_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Set TARGET_BRAVE_CHANNEL=none|release|origin (or legacy TARGET_BROWSER=release|origin)."
        exit 1
    fi

    ui_heading "Brave Browser"
    echo "    1) Brave Stable"
    echo "       Official release from Brave's repository (brave-browser package)"
    echo "       This is the standard Brave browser with all features enabled by default"
    echo "       Includes Leo AI, News, Playlist, Rewards, Wallet, VPN, and other integrated features"
    echo "       Completely free to use on all platforms with regular security updates"
    echo ""
    echo "    2) Brave Origin [default]"
    echo "       Origin build (brave-origin package) - a minimalist version of Brave"
    echo "       Streamlined to the core of Brave's ad blocking and privacy protections"
    echo "       Lets you manage or completely remove features you don't want"
    echo "       Removes daily usage pings, crash logs, and product analytics"
    echo "       FREE for Linux users (paid on other platforms)"
    echo "       Ideal for users who want a clean, privacy-focused browser without extra features"
    echo ""
    echo "    3) Skip Brave"
    echo "       Do not install Brave browser"
    echo "       Choose this if you prefer another browser or don't need Brave"
    echo ""

    local choice
    while true; do
        read -r -p "  Brave [1/2/3, Enter=2]: " choice
        case "${choice,,}" in
            1|r|release|stable)
                export TARGET_BRAVE_CHANNEL="release"
                break
                ;;
            ""|2|o|origin)
                export TARGET_BRAVE_CHANNEL="origin"
                break
                ;;
            3|n|none|skip)
                export TARGET_BRAVE_CHANNEL="none"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_BRAVE_CHANNEL=$TARGET_BRAVE_CHANNEL"
}

# interactive_toggle_pick VAR_NAME HEADING INSTALL_LABEL SKIP_LABEL PROMPT_LABEL
#   Generic yes/no pre-install toggle. Default answer is "skip" (0).
function interactive_toggle_pick() {
    local var_name="$1" heading="$2" install_label="$3" skip_label="$4" prompt_label="$5"

    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Set ${var_name}=0|1."
        exit 1
    fi

    ui_heading "$heading"
    echo "    1) ${install_label}"
    echo "    2) ${skip_label}  [default]"

    local choice
    while true; do
        read -r -p "  ${prompt_label} [1/2/3, Enter=2]: " choice
        case "${choice,,}" in
            ""|2|n|no|off|skip|s)
                export "$var_name"="0"
                break
                ;;
            1|y|yes|install|pre|on)
                export "$var_name"="1"
                break
                ;;
            3|none)
                export "$var_name"="0"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "${var_name}=${!var_name}"
}

function interactive_librewolf_pick() {
    interactive_toggle_pick TARGET_LIBREWOLF \
        "Librewolf" \
        "Pre-install librewolf (repo is configured either way)" \
        "Skip Librewolf" \
        "Librewolf"
}

function interactive_firefox_pick() {
    if [[ ! -t 0 ]]; then
        ui_err "No terminal is available. Set TARGET_FIREFOX=0|1 and TARGET_FIREFOX_ESR=0|1."
        exit 1
    fi

    ui_heading "Firefox Browser"
    echo "    1) Firefox Release [default]"
    echo "       Official release from Mozilla's repository (firefox package)"
    echo "       This is the standard Firefox browser with the latest features"
    echo "       Includes the newest web standards, performance improvements, and UI updates"
    echo "       Rapid release cycle with major updates every 4 weeks"
    echo "       Ideal for users who want cutting-edge features and the latest security patches"
    echo ""
    echo "    2) Firefox ESR"
    echo "       Extended Support Release (firefox-esr package) from Mozilla PPA"
    echo "       A slower-moving release designed for enterprise and institutional use"
    echo "       Receives security updates but fewer feature changes over time"
    echo "       Major updates only once per year, with maintenance updates for 54 weeks"
    echo "       Ideal for users who prefer stability and consistency over new features"
    echo "       Recommended for organizations that need standardized browser environments"
    echo ""
    echo "    3) Skip Firefox"
    echo "       Do not install Firefox browser"
    echo "       Choose this if you prefer another browser or don't need Firefox"
    echo ""

    local choice
    while true; do
        read -r -p "  Firefox [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            1|""|r|release)
                export TARGET_FIREFOX="1"
                export TARGET_FIREFOX_ESR="0"
                break
                ;;
            2|e|esr)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="1"
                break
                ;;
            3|n|none|skip)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="0"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_FIREFOX=$TARGET_FIREFOX  TARGET_FIREFOX_ESR=$TARGET_FIREFOX_ESR"
}

function interactive_thunderbird_pick() {
    interactive_toggle_pick TARGET_THUNDERBIRD \
        "Thunderbird (Mozilla PPA)" \
        "Pre-install thunderbird (Mozilla PPA + pin are configured either way)" \
        "Skip Thunderbird" \
        "Thunderbird"
}

function resolve_browser_selection() {
    if [[ -n "${TARGET_BROWSER:-}" && -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        export TARGET_BRAVE_CHANNEL="$TARGET_BROWSER"
    fi

    if [[ -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        if [[ -t 0 ]]; then
            interactive_brave_channel_pick
        else
            export TARGET_BRAVE_CHANNEL="release"
        fi
    fi

    if [[ -z "${TARGET_LIBREWOLF+x}" ]]; then
        if [[ -t 0 ]]; then
            interactive_librewolf_pick
        else
            export TARGET_LIBREWOLF="0"
        fi
    fi

    if [[ -z "${TARGET_FIREFOX+x}" || -z "${TARGET_FIREFOX_ESR+x}" ]]; then
        if [[ -t 0 ]]; then
            interactive_firefox_pick
        else
            export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
            export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
        fi
    fi

    if [[ -z "${TARGET_THUNDERBIRD+x}" ]]; then
        if [[ -t 0 ]]; then
            interactive_thunderbird_pick
        else
            export TARGET_THUNDERBIRD="0"
        fi
    fi

    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
}

function resolve_ubuntu_studio_choice() {
    if [[ -n "${TARGET_UBUNTU_STUDIO+x}" ]]; then
        export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
        return 0
    fi

    if [[ -t 0 ]]; then
        ui_heading "Ubuntu Studio"
        echo "    Large bundle: ubuntustudio-audio/graphics/photography/publishing/video,"
        echo "    ubuntustudio-wallpapers, ubuntustudio-menu, ubuntu-edu-music."
        local yn
        while true; do
            read -r -p "  Do you want to install Ubuntu Studio packages? (y/N) " yn
            yn="${yn,,}"
            [[ -z "$yn" ]] && yn="n"
            case "$yn" in
                y|yes)
                    export TARGET_UBUNTU_STUDIO="1"
                    break
                    ;;
                n|no)
                    export TARGET_UBUNTU_STUDIO="0"
                    break
                    ;;
                *)
                    echo "  Please answer y or n."
                    ;;
            esac
        done
        ui_ok "TARGET_UBUNTU_STUDIO=$TARGET_UBUNTU_STUDIO"
    else
        export TARGET_UBUNTU_STUDIO=0
    fi
}

function resolve_pacstall_choice() {
    if [[ -n "${TARGET_PACSTALL+x}" ]]; then
        export TARGET_PACSTALL="${TARGET_PACSTALL:-1}"
        return 0
    fi

    if [[ -t 0 ]]; then
        ui_heading "Pacstall"
        echo "    AUR-like package manager for Ubuntu (installed from https://pacstall.dev)."
        local yn
        while true; do
            read -r -p "  Install Pacstall? (Y/n) " yn
            yn="${yn,,}"
            [[ -z "$yn" ]] && yn="y"
            case "$yn" in
                y|yes)
                    export TARGET_PACSTALL="1"
                    break
                    ;;
                n|no)
                    export TARGET_PACSTALL="0"
                    break
                    ;;
                *)
                    echo "  Please answer y or n."
                    ;;
            esac
        done
        ui_ok "TARGET_PACSTALL=$TARGET_PACSTALL"
    else
        export TARGET_PACSTALL=1
    fi
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
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Build configuration"
    ui_kv "Ubuntu release"  "${TARGET_UBUNTU_VERSION:-?}${hv:+  (Ubuntu ${hv} LTS)}"
    ui_kv "Kernel"          "${TARGET_KERNEL_FLAVOR:-?}${TARGET_KERNEL_PACKAGE:+  [${TARGET_KERNEL_PACKAGE}]}"
    ui_kv "Desktop"         "${TARGET_DESKTOP:-?}"
    case "${TARGET_DESKTOP:-}" in
        gnome)  ui_kv "  with Recommends" "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" ;;
        kde-plasma) ui_kv "  KDE package" "${TARGET_KDE_PACKAGE:-kde-standard}" ;;
        mate)
            ui_kv "  MATE metapackage" "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            ui_kv "  MATE extras" "${TARGET_MATE_EXTRAS:-0}"
            ;;
    esac
    ui_kv "Installer"       "${TARGET_INSTALLER:-?}"
    local _bs=""
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none)              _bs="Brave: none" ;;
        release)           _bs="Brave: stable" ;;
        origin)            _bs="Brave: origin" ;;
    esac
    [[ "${TARGET_LIBREWOLF:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Librewolf"
    [[ "${TARGET_FIREFOX:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox"
    [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox ESR"
    [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Thunderbird"
    ui_kv "Browsers"       "${_bs}"
    ui_kv "Ubuntu Studio"  "${TARGET_UBUNTU_STUDIO:-0}"
    ui_kv "Pacstall"        "${TARGET_PACSTALL:-1}"
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

# load_config_file FILE — source a config file (key=value lines, # comments, blank lines).
# Only recognized TARGET_* and GRUB_LIVEBOOT_LABEL variables are exported.
# Unknown keys are ignored; the config cannot run arbitrary commands.
function load_config_file() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        ui_err "Config file not found: $config_path"
        exit 1
    fi
    ui_info "Loading config from: $config_path"
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments.
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip inline comments.
        line="${line%%#*}"
        # Match KEY=VALUE (with optional quotes).
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Strip surrounding quotes.
            val="${val#\"}" ; val="${val%\"}"
            val="${val#\'}" ; val="${val%\'}"
            val="${val## }" ; val="${val%% }"
            case "$key" in
                TARGET_UBUNTU_VERSION|TARGET_UBUNTU_MIRROR|TARGET_KERNEL_FLAVOR|\
                TARGET_KERNEL_PACKAGE|TARGET_DESKTOP|TARGET_KDE_PACKAGE|\
                TARGET_MATE_PACKAGE|TARGET_MATE_EXTRAS|TARGET_BROWSER|\
                TARGET_BRAVE_CHANNEL|TARGET_LIBREWOLF|TARGET_FIREFOX|\
                TARGET_FIREFOX_ESR|TARGET_THUNDERBIRD|TARGET_UBUNTU_STUDIO|\
                TARGET_PACSTALL|TARGET_GNOME_INSTALL_RECOMMENDS|TARGET_NAME|\
                TARGET_LOCALE|TARGET_KEYBOARD_LAYOUT|TARGET_KEYBOARD_VARIANT|\
                TARGET_INSTALLER|TARGET_PACKAGE_REMOVE|\
                GRUB_LIVEBOOT_LABEL|UBUNTU_VANILLA_WORKSPACE|NO_CONFIRM|\
                INTERACTIVE)
                    export "$key=$val"
                    ;;
                *)
                    ui_warn "Config: ignoring unknown key '$key'"
                    ;;
            esac
        fi
    done < "$config_path"
}

function host_main() {
    local cli_kernel=""
    local cli_release=""
    local cli_mirror=""
    local cli_installer=""
    local cli_desktop=""
    local cli_kde=""
    local cli_mate=""
    local cli_mate_extras_set=0
    local cli_mate_extras=0
    local cli_browser=""
    local cli_brave=""
    local cli_librewolf_set=0
    local cli_librewolf=0
    local cli_firefox_set=0
    local cli_firefox=0
    local cli_firefox_esr_set=0
    local cli_firefox_esr=0
    local cli_thunderbird_set=0
    local cli_thunderbird=0
    local cli_ubuntustudio_set=0
    local cli_ubuntustudio=0
    local cli_pacstall_set=0
    local cli_pacstall=0
    local cli_locale=""
    local cli_keyboard_layout=""
    local cli_keyboard_variant=""
    local cli_config=""
    local cli_interactive=""
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
            --installer=calamares|--installer=ubiquity)
                cli_installer="${1#--installer=}"
                shift
                ;;
            --installer)
                cli_installer="$2"
                shift 2
                ;;
            --desktop=*)
                cli_desktop="${1#--desktop=}"
                shift
                ;;
            --desktop)
                cli_desktop="$2"
                shift 2
                ;;
            --kde=kde-full|--kde=kde-standard|--kde=kde-plasma-desktop)
                cli_kde="${1#--kde=}"
                shift
                ;;
            --kde)
                cli_kde="$2"
                shift 2
                ;;
            --mate=*)
                cli_mate="${1#--mate=}"
                shift
                ;;
            --mate)
                cli_mate="$2"
                shift 2
                ;;
            --mate-extras)
                cli_mate_extras_set=1
                cli_mate_extras=1
                shift
                ;;
            --no-mate-extras)
                cli_mate_extras_set=1
                cli_mate_extras=0
                shift
                ;;
            --browser=release|--browser=origin)
                cli_browser="${1#--browser=}"
                shift
                ;;
            --browser)
                cli_browser="$2"
                shift 2
                ;;
            --brave=none|--brave=release|--brave=origin)
                cli_brave="${1#--brave=}"
                shift
                ;;
            --brave)
                cli_brave="$2"
                shift 2
                ;;
            --librewolf)
                cli_librewolf_set=1
                cli_librewolf=1
                shift
                ;;
            --no-librewolf)
                cli_librewolf_set=1
                cli_librewolf=0
                shift
                ;;
            --firefox)
                cli_firefox_set=1
                cli_firefox=1
                shift
                ;;
            --no-firefox)
                cli_firefox_set=1
                cli_firefox=0
                shift
                ;;
            --firefox-esr)
                cli_firefox_esr_set=1
                cli_firefox_esr=1
                shift
                ;;
            --no-firefox-esr)
                cli_firefox_esr_set=1
                cli_firefox_esr=0
                shift
                ;;
            --thunderbird)
                cli_thunderbird_set=1
                cli_thunderbird=1
                shift
                ;;
            --no-thunderbird)
                cli_thunderbird_set=1
                cli_thunderbird=0
                shift
                ;;
            --ubuntu-studio)
                cli_ubuntustudio_set=1
                cli_ubuntustudio=1
                shift
                ;;
            --no-ubuntu-studio)
                cli_ubuntustudio_set=1
                cli_ubuntustudio=0
                shift
                ;;
            --pacstall)
                cli_pacstall_set=1
                cli_pacstall=1
                shift
                ;;
            --no-pacstall)
                cli_pacstall_set=1
                cli_pacstall=0
                shift
                ;;
            --locale=*)
                cli_locale="${1#--locale=}"
                shift
                ;;
            --locale)
                cli_locale="$2"
                shift 2
                ;;
            --keyboard-layout=*)
                cli_keyboard_layout="${1#--keyboard-layout=}"
                shift
                ;;
            --keyboard-layout)
                cli_keyboard_layout="$2"
                shift 2
                ;;
            --keyboard-variant=*)
                cli_keyboard_variant="${1#--keyboard-variant=}"
                shift
                ;;
            --keyboard-variant)
                cli_keyboard_variant="$2"
                shift 2
                ;;
            --config=*)
                cli_config="${1#--config=}"
                shift
                ;;
            --config)
                cli_config="$2"
                shift 2
                ;;
            --interactive)
                cli_interactive="1"
                shift
                ;;
            --no-interactive)
                cli_interactive="0"
                shift
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

    # Load config file (if specified). Config values act as defaults; CLI flags override them below.
    if [[ -n "$cli_config" ]]; then
        load_config_file "$cli_config"
    elif [[ -f "$SCRIPT_DIR/build.conf" ]]; then
        # Auto-detect config file in the scripts directory.
        load_config_file "$SCRIPT_DIR/build.conf"
    fi

    # Handle --interactive / --no-interactive. The INTERACTIVE variable can also come from the config file.
    # --no-interactive: redirect stdin from /dev/null so that all [[ -t 0 ]] checks return false,
    # making the build fully non-interactive (all missing values use defaults or fail with an error).
    # --interactive: force interactive mode even when stdin is not a TTY (e.g. piped).
    if [[ "$cli_interactive" == "0" ]] || [[ "${INTERACTIVE:-}" == "0" && -z "$cli_interactive" ]]; then
        exec 0</dev/null
        export NO_CONFIRM=1
    fi

    cd "$SCRIPT_DIR"
    resolve_workspace_paths

    ui_banner "Ubuntu Vanilla ISO Builder"
    ui_kv "Script"     "$0"
    ui_kv "Workspace"  "$WORKSPACE_DIR"
    ui_kv "Started at" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    HOST_ABORT_CLEANUP_DONE=0
    CHROOT_MOUNTS_ACTIVE=0
    trap host_build_exit_trap EXIT
    trap 'host_build_signal_trap 130' INT
    trap 'host_build_signal_trap 143' TERM

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
    if [[ -n "$cli_kde" ]]; then
        export TARGET_KDE_PACKAGE="$cli_kde"
    fi
    if [[ -n "$cli_mate" ]]; then
        export TARGET_MATE_PACKAGE="$cli_mate"
    fi
    if [[ "$cli_mate_extras_set" -eq 1 ]]; then
        export TARGET_MATE_EXTRAS="$cli_mate_extras"
    fi
    if [[ -n "$cli_browser" ]]; then
        export TARGET_BROWSER="$cli_browser"
    fi
    if [[ -n "$cli_brave" ]]; then
        export TARGET_BRAVE_CHANNEL="$cli_brave"
    fi
    if [[ "$cli_librewolf_set" -eq 1 ]]; then
        export TARGET_LIBREWOLF="$cli_librewolf"
    fi
    if [[ "$cli_firefox_set" -eq 1 ]]; then
        export TARGET_FIREFOX="$cli_firefox"
    fi
    if [[ "$cli_firefox_esr_set" -eq 1 ]]; then
        export TARGET_FIREFOX_ESR="$cli_firefox_esr"
    fi
    if [[ "$cli_thunderbird_set" -eq 1 ]]; then
        export TARGET_THUNDERBIRD="$cli_thunderbird"
    fi
    if [[ "$cli_ubuntustudio_set" -eq 1 ]]; then
        export TARGET_UBUNTU_STUDIO="$cli_ubuntustudio"
    fi
    if [[ "$cli_pacstall_set" -eq 1 ]]; then
        export TARGET_PACSTALL="$cli_pacstall"
    fi
    if [[ -n "$cli_locale" ]]; then
        export TARGET_LOCALE="$cli_locale"
    fi
    if [[ -n "$cli_keyboard_layout" ]]; then
        export TARGET_KEYBOARD_LAYOUT="$cli_keyboard_layout"
    fi
    if [[ -n "$cli_keyboard_variant" ]]; then
        export TARGET_KEYBOARD_VARIANT="$cli_keyboard_variant"
    fi

    if [[ -z "${TARGET_UBUNTU_VERSION:-}" ]]; then
        resolve_release_choice
    fi

    if [[ -z "${TARGET_INSTALLER:-}" ]]; then
        resolve_installer_choice
    fi
    set_installer_and_manifest_defaults

    validate_ubiquity_jammy_only

    if [[ -z "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        resolve_kernel_choice
    fi
    if [[ -z "${TARGET_DESKTOP:-}" ]]; then
        resolve_desktop_choice
    fi
    normalize_desktop_variant
    if [[ -z "${TARGET_NAME:-}" ]]; then
        export TARGET_NAME
        TARGET_NAME="$(default_target_name)"
    fi
    if [[ -z "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        resolve_gnome_recommends_choice
    fi
    resolve_kde_package_choice
    resolve_mate_choice
    resolve_browser_selection
    resolve_ubuntu_studio_choice
    resolve_pacstall_choice

    check_settings
    set_target_kernel_package_from_flavor
    check_host_user

    local start_index end_index
    parse_cmd_range HOST_CMD host_help "$@"

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
    ubuntu_version="$(release_version "$TARGET_UBUNTU_VERSION")"
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

    # Locale configuration: if TARGET_LOCALE is set, pre-seed debconf for unattended operation.
    if [[ -n "${TARGET_LOCALE:-}" ]]; then
        echo "=====> Configuring locale: ${TARGET_LOCALE}"
        sed -i "s/^# *${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen 2>/dev/null || true
        echo "${TARGET_LOCALE}" >> /etc/locale.gen
        sort -u -o /etc/locale.gen /etc/locale.gen
        echo "locales locales/default_environment_locale select ${TARGET_LOCALE}" | debconf-set-selections
        echo "locales locales/locales_to_be_generated multiselect ${TARGET_LOCALE}" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive locales
    else
        dpkg-reconfigure locales
    fi

    # Keyboard configuration: if TARGET_KEYBOARD_LAYOUT is set, pre-seed for unattended operation.
    if [[ -n "${TARGET_KEYBOARD_LAYOUT:-}" ]]; then
        local _kb_variant="${TARGET_KEYBOARD_VARIANT:-}"
        echo "=====> Configuring keyboard: layout=${TARGET_KEYBOARD_LAYOUT}${_kb_variant:+, variant=${_kb_variant}}"
        apt-get install -y keyboard-configuration console-setup 2>/dev/null || true
        echo "keyboard-configuration keyboard-configuration/layoutcode select ${TARGET_KEYBOARD_LAYOUT}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/variant select ${_kb_variant}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/model select pc105" | debconf-set-selections
        echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive keyboard-configuration
        dpkg-reconfigure --frontend=noninteractive console-setup
    fi

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

    local _memtest_url="https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip"
    local _memtest_sha256="19894151788a99c25c42644696527aba18cb210b2f9bca4a60e73586a6d78286"
    wget --progress=dot "$_memtest_url" -O install/memtest86.zip
    echo "${_memtest_sha256}  install/memtest86.zip" | sha256sum -c - || {
        >&2 echo "ERROR: Memtest86+ archive checksum mismatch — aborting."
        rm -f install/memtest86.zip
        exit 1
    }
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

    local _efi_src
    for _efi_src in /usr/lib/shim/shimx64.efi.signed.previous /usr/lib/shim/mmx64.efi /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed; do
        if [[ ! -f "$_efi_src" ]]; then
            echo "ERROR: Required EFI binary '$_efi_src' not found. Ensure shim-signed and grub-efi-amd64-signed are installed." >&2
            exit 1
        fi
    done
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

    find . -type f -print0 \
        | xargs -0 md5sum \
        | grep -v -e 'boot/grub/efiboot.img' -e 'boot/grub/bios.img' -e 'md5sum.txt' \
        > md5sum.txt

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
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
    normalize_desktop_variant
    if [[ -n "${TARGET_BROWSER:-}" && -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        export TARGET_BRAVE_CHANNEL="$TARGET_BROWSER"
    fi
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}"
    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
    export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
    validate_ubiquity_jammy_only
    check_settings
    set_target_kernel_package_from_flavor
    check_chroot_root

    local start_index end_index
    parse_cmd_range CHROOT_CMD chroot_help "$@"

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
