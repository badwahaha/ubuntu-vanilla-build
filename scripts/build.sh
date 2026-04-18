#!/bin/bash

set -e                  # exit on error
set -o pipefail         # exit on pipeline error
set -u                  # treat unset variable as error

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Host (outside chroot): prepare tree, debootstrap, run chroot phase, squashfs + ISO
HOST_CMD=(setup_host debootstrap run_chroot build_iso)

# Chroot phase: APT setup, packages, /image layout, cleanup
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

DATE=`TZ="UTC" date +"%y%m%d-%H%M%S"`

# --- shared ---

function load_config() {
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/config.sh"
    elif [[ -f "$SCRIPT_DIR/default_config.sh" ]]; then
        # shellcheck source=/dev/null
        . "$SCRIPT_DIR/default_config.sh"
    else
        >&2 echo "Unable to find default config file  $SCRIPT_DIR/default_config.sh, aborting."
        exit 1
    fi
}

function check_config() {
    local expected_config_version
    expected_config_version="0.7"

    if [[ "$CONFIG_FILE_VERSION" != "$expected_config_version" ]]; then
        >&2 echo "Invalid or old config version $CONFIG_FILE_VERSION, expected $expected_config_version. Please update your configuration file from the default."
        exit 1
    fi
    if declare -F assert_supported_release >/dev/null; then
        assert_supported_release || exit 1
    fi
}

# --- host ---

function host_help() {
    if [ -z ${1+x} ]; then
        echo -e "This script builds a bootable ubuntu ISO image"
        echo -e
    else
        echo -e "$1"
        echo
    fi
    echo -e "Supported commands : ${HOST_CMD[*]}"
    echo -e
    echo -e "Kernel (HWE only; XX.04 = 22 / 24 / 26 from jammy / noble / resolute):"
    echo -e "  --kernel=generic|lowlatency              linux-generic-hwe-XX.04 or linux-lowlatency-hwe-XX.04"
    echo -e "  --kernel-recommends=yes|no               apt recommends for kernel metapackage (default: no)"
    echo -e "  -i, --interactive                        prompt for kernel (terminal only)"
    echo -e
    echo -e "Syntax: $0 [options] [start_cmd] [-] [end_cmd]"
    echo -e "\trun from start_cmd to end_end"
    echo -e "\tif start_cmd is omitted, start from first command"
    echo -e "\tif end_cmd is omitted, end with last command"
    echo -e "\tenter single cmd to run the specific command"
    echo -e "\tenter '-' as only argument to run all commands"
    echo -e
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
    host_help "Command not found : $1"
}

function check_host_user() {
    local os_ver
    os_ver=`lsb_release -i | grep -E "(Ubuntu|Debian)"`
    if [[ -z "$os_ver" ]]; then
        echo "WARNING : OS is not Debian or Ubuntu and is untested"
    fi

    if [ $(id -u) -eq 0 ]; then
        echo "This script should not be run as 'root'"
        exit 1
    fi
}

function chroot_enter_setup() {
    sudo mount --bind /dev chroot/dev
    sudo mount --bind /run chroot/run
    sudo chroot chroot mount none -t proc /proc
    sudo chroot chroot mount none -t sysfs /sys
    sudo chroot chroot mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    sudo chroot chroot umount -l /proc
    sudo chroot chroot umount -l /sys
    sudo chroot chroot umount -l /dev/pts
    sudo umount -l chroot/dev
    sudo umount -l chroot/run
}

function setup_host() {
    echo "=====> running setup_host ..."
    sudo apt update
    sudo apt install -y debootstrap squashfs-tools xorriso
    sudo mkdir -p chroot
}

function debootstrap() {
    echo "=====> running debootstrap ... will take a couple of minutes ..."
    sudo debootstrap --arch=amd64 --variant=minbase $TARGET_UBUNTU_VERSION chroot $TARGET_UBUNTU_MIRROR
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    chroot_enter_setup

    sudo ln -f "$SCRIPT_DIR/build.sh" chroot/root/build.sh
    sudo ln -f "$SCRIPT_DIR/default_config.sh" chroot/root/default_config.sh
    if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
        sudo ln -f "$SCRIPT_DIR/config.sh" chroot/root/config.sh
    fi

    sudo chroot chroot /usr/bin/env \
        DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-readline} \
        TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" \
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
        TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-}" \
        /root/build.sh --chroot-internal -

    sudo rm -f chroot/root/build.sh
    sudo rm -f chroot/root/default_config.sh
    if [[ -f "chroot/root/config.sh" ]]; then
        sudo rm -f chroot/root/config.sh
    fi

    chroot_exit_teardown
}

function build_iso() {
    echo "=====> running build_iso ..."

    sudo mv chroot/image .

    sudo mksquashfs chroot image/casper/filesystem.squashfs \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile"

    printf $(sudo du -sx --block-size=1 chroot | cut -f1) | sudo tee image/casper/filesystem.size

    pushd $SCRIPT_DIR/image

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
        --grub2-mbr ../chroot/usr/lib/grub/i386-pc/boot_hybrid.img \
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

    popd
}

function interactive_kernel_pick() {
    if [[ ! -t 0 ]]; then
        echo "Not a terminal; use --kernel=generic|lowlatency or set TARGET_KERNEL_FLAVOR in config.sh" >&2
        return 0
    fi
    local hv=""
    if declare -F hwe_version_for_release >/dev/null; then
        hv=$(hwe_version_for_release "$TARGET_UBUNTU_VERSION")
    fi
    echo ""
    echo "Pilih kernel Ubuntu HWE (22.04 / 24.04 / 26.04 untuk jammy / noble / resolute) — ${TARGET_UBUNTU_VERSION}${hv:+ -> paket *-hwe-${hv}}:"
    PS3="Nomor [1-3]: "
    select _opt in \
        "linux-generic-hwe (disarankan)" \
        "linux-lowlatency-hwe (audio / latensi rendah)" \
        "Gunakan nilai dari config (tidak mengubah)"; do
        case $REPLY in
            1)
                export TARGET_KERNEL_FLAVOR=generic
                echo "=> TARGET_KERNEL_FLAVOR=generic"
                break
                ;;
            2)
                export TARGET_KERNEL_FLAVOR=lowlatency
                echo "=> TARGET_KERNEL_FLAVOR=lowlatency"
                break
                ;;
            3)
                echo "=> tidak diubah"
                break
                ;;
            *)
                echo "Pilihan tidak valid."
                ;;
        esac
    done
    echo ""
}

function host_main() {
    local interactive=0
    local cli_kernel=""
    local cli_krec=""
    local args=()
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
    load_config

    if [[ -n "$cli_kernel" ]]; then
        case "$cli_kernel" in
            generic|lowlatency)
                export TARGET_KERNEL_FLAVOR="$cli_kernel"
                ;;
            *)
                >&2 echo "Invalid --kernel value: use generic or lowlatency"
                exit 1
                ;;
        esac
    fi

    if [[ -n "$cli_krec" ]]; then
        export TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS="$cli_krec"
    fi

    if [[ "$interactive" -eq 1 ]]; then
        interactive_kernel_pick
    fi

    if declare -F set_target_kernel_package_from_flavor >/dev/null; then
        set_target_kernel_package_from_flavor
    fi

    check_config
    check_host_user

    if [[ $# == 0 || $# > 3 ]]; then host_help; fi

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
            end_index=$(($index+1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$(($start_index + 1))
    fi

    local i
    for ((i=$start_index; i<$end_index; i++)); do
        ${HOST_CMD[i]}
    done

    echo "$0 - Initial build is done!"
}

# --- chroot ---

function chroot_help() {
    if [ -z ${1+x} ]; then
        echo -e "Chroot phase: build rootfs and live image layout under /image"
        echo -e
    else
        echo -e "$1"
        echo
    fi
    echo -e "Supported commands : ${CHROOT_CMD[*]}"
    echo -e
    echo -e "Syntax: $0 --chroot-internal [start_cmd] [-] [end_cmd]"
    echo -e
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
    chroot_help "Command not found : $1"
}

function check_chroot_root() {
    if [ $(id -u) -ne 0 ]; then
        echo "Chroot phase must run as root"
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
    echo "=====> running install_pkg ... will take a long time ..."
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

    # jammy / noble / resolute: lupin-casper not used

    local kernel_apt_opts=(-y)
    if [[ "${TARGET_KERNEL_METAPACKAGE_INSTALL_RECOMMENDS:-no}" != "yes" ]]; then
        kernel_apt_opts+=(--no-install-recommends)
    fi
    echo "=====> kernel metapackage apt: ${kernel_apt_opts[*]} $TARGET_KERNEL_PACKAGE"
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

    pushd /image

    local vmlinuz_src initrd_src
    vmlinuz_src=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    initrd_src=$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
    if [[ -z "${vmlinuz_src:-}" || ! -f "$vmlinuz_src" ]]; then
        echo "No /boot/vmlinuz-* found; kernel install failed?" >&2
        exit 1
    fi
    if [[ -z "${initrd_src:-}" || ! -f "$initrd_src" ]]; then
        echo "No /boot/initrd.img-* found; kernel install failed?" >&2
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

menuentry "Try Ubuntu FS without installing" {
    linux /casper/vmlinuz boot=casper nopersistent toram quiet splash ---
    initrd /casper/initrd
}

menuentry "Install Ubuntu FS" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

grub_platform
if [ "\$grub_platform" = "efi" ]; then
menuentry 'UEFI Firmware Settings' {
    fwsetup
}

menuentry "Test memory Memtest86+ (UEFI)" {
    linux /install/memtest86+.efi
}
else
menuentry "Test memory Memtest86+ (BIOS)" {
    linux16 /install/memtest86+.bin
}
fi
EOF

    dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee casper/filesystem.manifest

    cp -v casper/filesystem.manifest casper/filesystem.manifest-desktop

    local pkg
    for pkg in $TARGET_PACKAGE_REMOVE; do
        sudo sed -i "/$pkg/d" casper/filesystem.manifest-desktop
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
        cd isolinux && \
        dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
        mkfs.vfat -F 16 efiboot.img && \
        LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot && \
        LC_CTYPE=C mcopy -i efiboot.img ./bootx64.efi ::efi/boot/bootx64.efi && \
        LC_CTYPE=C mcopy -i efiboot.img ./mmx64.efi ::efi/boot/mmx64.efi && \
        LC_CTYPE=C mcopy -i efiboot.img ./grubx64.efi ::efi/boot/grubx64.efi && \
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

    popd
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
    load_config
    check_config
    if declare -F set_target_kernel_package_from_flavor >/dev/null; then
        set_target_kernel_package_from_flavor
    fi
    check_chroot_root

    if [[ $# == 0 || $# > 3 ]]; then chroot_help; fi

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
            end_index=$(($index+1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$(($start_index + 1))
    fi

    local i
    for ((i=$start_index; i<$end_index; i++)); do
        ${CHROOT_CMD[i]}
    done

    echo "$0 --chroot-internal - Chroot phase done!"
}

# =============   entry  ================

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main "$@"
else
    host_main "$@"
fi
