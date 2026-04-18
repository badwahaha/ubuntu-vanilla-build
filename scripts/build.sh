#!/bin/bash

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
WORKSPACE_DIR="$SCRIPT_DIR/workspace"
WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
WORKSPACE_IMAGE="$WORKSPACE_DIR/image"
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"

# Host (outside chroot): prepare tree, debootstrap, run chroot phase, squashfs + ISO
HOST_CMD=(setup_host debootstrap run_chroot build_iso)

# Chroot phase: APT setup, packages, /image layout, cleanup
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

function set_defaults() {
    export TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}"
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-http://us.archive.ubuntu.com/ubuntu/}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-no}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_NAME="${TARGET_NAME:-ubuntu-from-scratch}"
    export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Ubuntu FS without installing}"
    export GRUB_INSTALL_LABEL="${GRUB_INSTALL_LABEL:-Install Ubuntu FS}"
    export TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-\
ubiquity \
casper \
discover \
laptop-detect \
os-prober \
}"
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

function customize_image() {
    apt-get install -y \
        plymouth-themes \
        vanilla-gnome-desktop

    apt-get install -y \
        clamav-daemon \
        terminator \
        apt-transport-https \
        curl \
        vim \
        nano \
        less

    apt-get purge -y \
        transmission-gtk \
        transmission-common \
        gnome-mahjongg \
        gnome-mines \
        gnome-sudoku \
        aisleriot \
        hitori
}

function check_settings() {
    assert_supported_release || exit 1
    case "${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-}" in
        yes|no) ;;
        *)
            >&2 echo "TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS must be yes or no."
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
    echo "  --kernel=generic|lowlatency             Kernel type to install"
    echo "  --kernel-recommends=yes|no              Install apt Recommends for the kernel metapackage"
    echo "  -i, --interactive                       Ask for release and kernel on a TTY (same as omitting them)"
    echo
    echo "Syntax: $0 [options] [start_cmd] [-] [end_cmd]"
    echo "  Run from start_cmd to end_cmd"
    echo "  If start_cmd is omitted, start from the first command"
    echo "  If end_cmd is omitted, stop after the selected command"
    echo "  Use a single command to run only that command"
    echo "  Use '-' by itself to run all commands"
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
    local os_ver
    os_ver="$(lsb_release -i | grep -E "(Ubuntu|Debian)" || true)"
    if [[ -z "$os_ver" ]]; then
        echo "WARNING: This host is not Ubuntu or Debian, so the build is untested here."
    fi

    if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this script as root."
        exit 1
    fi
}

function ensure_workspace_root() {
    sudo mkdir -p "$WORKSPACE_DIR"
}

function clean_workspace() {
    if [[ -e "$WORKSPACE_DIR" ]]; then
        echo "=====> removing workspace ..."
        sudo rm -rf "$WORKSPACE_DIR"
    fi
}

function chroot_enter_setup() {
    sudo mount --bind /dev "$WORKSPACE_CHROOT/dev"
    sudo mount --bind /run "$WORKSPACE_CHROOT/run"
    sudo chroot "$WORKSPACE_CHROOT" mount none -t proc /proc
    sudo chroot "$WORKSPACE_CHROOT" mount none -t sysfs /sys
    sudo chroot "$WORKSPACE_CHROOT" mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    sudo chroot "$WORKSPACE_CHROOT" umount -l /proc
    sudo chroot "$WORKSPACE_CHROOT" umount -l /sys
    sudo chroot "$WORKSPACE_CHROOT" umount -l /dev/pts
    sudo umount -l "$WORKSPACE_CHROOT/dev"
    sudo umount -l "$WORKSPACE_CHROOT/run"
}

function setup_host() {
    echo "=====> running setup_host ..."
    sudo apt update
    sudo apt install -y debootstrap squashfs-tools xorriso
    clean_workspace
    ensure_workspace_root
    sudo mkdir -p "$WORKSPACE_CHROOT"
}

function debootstrap() {
    echo "=====> running debootstrap ... this will take a few minutes ..."
    sudo debootstrap --arch=amd64 --variant=minbase "$TARGET_UBUNTU_VERSION" "$WORKSPACE_CHROOT" "$TARGET_UBUNTU_MIRROR"
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    chroot_enter_setup

    sudo cp "$SCRIPT_DIR/build.sh" "$WORKSPACE_CHROOT/root/build.sh"

    sudo chroot "$WORKSPACE_CHROOT" /usr/bin/env \
        DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-readline}" \
        TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION}" \
        TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
        TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" \
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
        TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-}" \
        TARGET_NAME="${TARGET_NAME}" \
        GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL}" \
        GRUB_INSTALL_LABEL="${GRUB_INSTALL_LABEL}" \
        TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE}" \
        /root/build.sh --chroot-internal -

    sudo rm -f "$WORKSPACE_CHROOT/root/build.sh"

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
    sudo rm -rf "$WORKSPACE_IMAGE"
    sudo mv "$WORKSPACE_CHROOT/image" "$WORKSPACE_IMAGE"

    sudo mksquashfs "$WORKSPACE_CHROOT" "$WORKSPACE_IMAGE/casper/filesystem.squashfs" \
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

    printf "%s" "$(sudo du -sx --block-size=1 "$WORKSPACE_CHROOT" | cut -f1)" | sudo tee "$WORKSPACE_IMAGE/casper/filesystem.size" >/dev/null

    pushd "$WORKSPACE_IMAGE" >/dev/null

    sudo xorriso \
        -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -J -J -joliet-long \
        -volid "$TARGET_NAME" \
        -output "$SCRIPT_DIR/$TARGET_NAME.iso" \
      -eltorito-boot isolinux/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot.catalog \
        --grub2-boot-info \
        --grub2-mbr "$WORKSPACE_CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img" \
        -partition_offset 16 \
        --mbr-force-bootable \
      -eltorito-alt-boot \
        -no-emul-boot \
        -e isolinux/efiboot.img \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b isolinux/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -m "isolinux/efiboot.img" \
        -m "isolinux/bios.img" \
        -e '--interval:appended_partition_2:::' \
      -exclude isolinux \
      -graft-points \
         "/EFI/boot/bootx64.efi=isolinux/bootx64.efi" \
         "/EFI/boot/mmx64.efi=isolinux/mmx64.efi" \
         "/EFI/boot/grubx64.efi=isolinux/grubx64.efi" \
         "/EFI/ubuntu/grub.cfg=isolinux/grub.cfg" \
         "/isolinux/bios.img=isolinux/bios.img" \
         "/isolinux/efiboot.img=isolinux/efiboot.img" \
         "."

    popd >/dev/null

    write_iso_hashes
    clean_workspace
}

function interactive_release_pick() {
    if [[ ! -t 0 ]]; then
        >&2 echo "No terminal is available. Use --release=jammy|noble|resolute."
        exit 1
    fi

    echo
    echo "Choose the Ubuntu release to build:"
    PS3="Selection [1-3]: "
    select _opt in \
        "jammy (22.04 LTS)" \
        "noble (24.04 LTS)" \
        "resolute (26.04 LTS)"; do
        case "$REPLY" in
            1)
                export TARGET_UBUNTU_VERSION="jammy"
                echo "=> TARGET_UBUNTU_VERSION=jammy"
                break
                ;;
            2)
                export TARGET_UBUNTU_VERSION="noble"
                echo "=> TARGET_UBUNTU_VERSION=noble"
                break
                ;;
            3)
                export TARGET_UBUNTU_VERSION="resolute"
                echo "=> TARGET_UBUNTU_VERSION=resolute"
                break
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
    echo
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
        >&2 echo "No terminal is available. Use --kernel=generic|lowlatency."
        exit 1
    fi

    local hv=""
    hv="$(hwe_version_for_release "$TARGET_UBUNTU_VERSION")"

    echo
    echo "Choose the Ubuntu HWE kernel type for $TARGET_UBUNTU_VERSION${hv:+ (*-hwe-${hv})}:"
    PS3="Selection [1-2]: "
    select _opt in \
        "generic (recommended for most systems)" \
        "lowlatency (better for audio and low-latency workloads)"; do
        case "$REPLY" in
            1)
                export TARGET_KERNEL_FLAVOR="generic"
                echo "=> TARGET_KERNEL_FLAVOR=generic"
                break
                ;;
            2)
                export TARGET_KERNEL_FLAVOR="lowlatency"
                echo "=> TARGET_KERNEL_FLAVOR=lowlatency"
                break
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
    echo
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

function host_main() {
    local interactive=0
    local cli_kernel=""
    local cli_release=""
    local cli_mirror=""
    local cli_krec=""
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
            --kernel-recommends=yes|--kernel-recommends=no)
                cli_krec="${1#--kernel-recommends=}"
                shift
                ;;
            -i|--interactive)
                interactive=1
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

    cd "$SCRIPT_DIR"

    if [[ -n "$cli_release" ]]; then
        export TARGET_UBUNTU_VERSION="$cli_release"
    fi
    if [[ -n "$cli_mirror" ]]; then
        export TARGET_UBUNTU_MIRROR="$cli_mirror"
    fi
    if [[ -n "$cli_kernel" ]]; then
        export TARGET_KERNEL_FLAVOR="$cli_kernel"
    fi
    if [[ -n "$cli_krec" ]]; then
        export TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="$cli_krec"
    fi

    if [[ "$interactive" -eq 1 || -z "${TARGET_UBUNTU_VERSION:-}" ]]; then
        resolve_release_choice
    fi

    check_settings

    if [[ "$interactive" -eq 1 || -z "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        resolve_kernel_choice
    fi

    set_target_kernel_package_from_flavor
    check_host_user

    if [[ $# == 0 || $# > 3 ]]; then
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

    local i
    for ((i=start_index; i<end_index; i++)); do
        "${HOST_CMD[i]}"
    done

    echo "$0 - Initial build is done."
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

    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
Package: snapd
Pin: release *
Pin-Priority: -1
EOF

    apt-get install -y libterm-readline-gnu-perl systemd-sysv

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    ln -s /bin/true /sbin/initctl
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
        wireless-tools \
        wpagui \
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

    local kernel_apt_opts=(-y)
    if [[ "${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-no}" != "yes" ]]; then
        kernel_apt_opts+=(--no-install-recommends)
    fi
    echo "=====> kernel metapackage apt options: ${kernel_apt_opts[*]} $TARGET_KERNEL_PACKAGE"
    apt-get install "${kernel_apt_opts[@]}" "$TARGET_KERNEL_PACKAGE"

    apt-get install -y \
        ubiquity \
        ubiquity-casper \
        ubiquity-frontend-gtk \
        ubiquity-ubuntu-artwork

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
    mkdir -p /image/{casper,isolinux,install}

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
    cat <<EOF > isolinux/grub.cfg

search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=30

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper nopersistent toram quiet splash ---
    initrd /casper/initrd
}

menuentry "$GRUB_INSTALL_LABEL" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
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

    cp /usr/lib/shim/shimx64.efi.signed.previous isolinux/bootx64.efi
    cp /usr/lib/shim/mmx64.efi isolinux/mmx64.efi
    cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed isolinux/grubx64.efi

    (
        cd isolinux
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        mkfs.vfat -F 16 efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot
        LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/bootx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./mmx64.efi ::efi/boot/mmx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./grubx64.efi ::efi/boot/grubx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/ubuntu/grub.cfg
    )

    grub-mkstandalone \
      --format=i386-pc \
      --output=isolinux/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=isolinux/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img isolinux/core.img > isolinux/bios.img

    /bin/bash -c "(find . -type f -print0 | xargs -0 md5sum | grep -v -e 'isolinux' > md5sum.txt)"

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
