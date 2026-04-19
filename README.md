# Build your own Ubuntu ISO with vanilla way without `snapd` and more clear

This guide shows how to build a bootable Ubuntu live ISO from a minimal base: **vanilla GNOME** (via `vanilla-gnome-desktop`), **no Snap** (snapd is blocked permanently with APT pinning), and a **slim Ubiquity** install (no slideshow packages). **GParted** and common **filesystem tools** are installed so disk preparation matches what the graphical installer expects.

**Supported Ubuntu releases (only these):**

| Codename   | Version   | HWE metapackage suffix | Common name        |
| ---------- | --------- | ---------------------- | ------------------ |
| `jammy`    | 22.04 LTS | `-hwe-22.04`           | Jammy Jellyfish    |
| `noble`    | 24.04 LTS | `-hwe-24.04`           | Noble Numbat       |
| `resolute` | 26.04 LTS | `-hwe-26.04`           | Resolute Raccoon   |

Use a **host** that is the same release as your target or newer (for example, build `jammy` on 22.04+; `noble` on 24.04+; `resolute` on 26.04+ when available). While **Resolute** is still rolling toward GA, use a current daily/beta host or build from a matching environment; use a mirror that publishes the target suite.

The main flow is: build environment → `debootstrap` → work **inside the chroot** (including preparing `/image`) → exit the chroot → **squashfs** → **xorriso**.

## Requirements

- Comfort with the Linux shell and scripting.
- Enough disk space and RAM for bootstrapping and building the ISO.
- Host Ubuntu version **≥** target release (`jammy`, `noble`, or `resolute`), as in the table above.

## Quick start (recommended)

Run from the `scripts` directory. On a normal terminal, if you omit `--release` or `--kernel`, the script asks first for the Ubuntu release, then for the kernel type. Optional: `--kernel-recommends=yes|no` controls apt **Recommends** for the kernel metapackage only. For fully non-interactive runs, pass both `--release` and `--kernel`:

```shell
./build.sh -
./build.sh --release=jammy --kernel=generic -
./build.sh --release=noble --kernel=lowlatency --kernel-recommends=yes -
```

That runs: host setup -> `debootstrap` -> scripts inside the chroot (including snapd block, Ubiquity + disk tools, vanilla GNOME) -> ISO creation. Temporary build files live under `scripts/workspace/{chroot,image}` while the build runs, then `workspace` is deleted after the ISO, SHA-1 file, and SHA-256 file are written.

## Terminology

- **Build system** — the machine where you run the build scripts (the host).
- **Live system** — the root filesystem built inside the chroot; this becomes the live ISO contents.
- **Target system** — the installation on disk after the user runs the installer from the live environment.

## Manual procedure (overview)

The order matches `scripts/build.sh`: the **chroot phase** (same file, `--chroot-internal`) finishes **all steps inside the chroot** (including creating `/image` and boot files), then **exit the chroot**, then **squashfs compression** and **ISO creation** run on the host.

Set `RELEASE` to `jammy`, `noble`, or `resolute` for the commands below. Example working directory: `$HOME/live-ubuntu-from-scratch`.

---

### 1. On the host: dependencies and working directory

```shell
sudo apt-get update
sudo apt-get install -y debootstrap squashfs-tools xorriso

mkdir -p "$HOME/live-ubuntu-from-scratch"
cd "$HOME/live-ubuntu-from-scratch"
```

### 2. On the host: `debootstrap` and bind mounts

```shell
RELEASE=noble   # or: jammy | resolute

sudo debootstrap \
   --arch=amd64 \
   --variant=minbase \
   "$RELEASE" \
   "$HOME/live-ubuntu-from-scratch/chroot" \
   http://archive.ubuntu.com/ubuntu/

sudo mount --bind /dev "$HOME/live-ubuntu-from-scratch/chroot/dev"
sudo mount --bind /run "$HOME/live-ubuntu-from-scratch/chroot/run"
```

---

### 3. Inside the chroot: bootstrap the live system

Enter the chroot, then mount the required virtual filesystems:

```shell
sudo chroot "$HOME/live-ubuntu-from-scratch/chroot"
```

```shell
mount none -t proc /proc
mount none -t sysfs /sys
mount none -t devpts /dev/pts

export HOME=/root
export LC_ALL=C
```

Set `RELEASE` to match what you used in `debootstrap` (`jammy`, `noble`, or `resolute`). Then hostname, `sources.list`, and **permanent snapd block** (before any upgrade that could pull in snapd):

```shell
RELEASE=noble   # must match debootstrap (jammy | noble | resolute)

echo "ubuntu-fs-live" > /etc/hostname

cat <<EOF > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse
EOF

apt-get update

install -d /etc/apt/preferences.d
cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
# Never install snapd
Package: snapd
Pin: release *
Pin-Priority: -1
EOF

apt-get install -y libterm-readline-gnu-perl systemd-sysv

dbus-uuidgen > /etc/machine-id
ln -fs /etc/machine-id /var/lib/dbus/machine-id

dpkg-divert --local --rename --add /sbin/initctl
ln -s /bin/true /sbin/initctl

apt-get -y upgrade
```

Core packages for the live system, kernel, **Calamares** (via `calamares-settings-ubuntu-unity` on noble/resolute, or `calamares` + `calamares-settings-debian` on jammy), and disk tooling (GParted + filesystem utilities):

```shell
apt-get install -y \
   sudo ubuntu-standard casper discover laptop-detect os-prober \
   network-manager net-tools wireless-tools wpagui locales \
   grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common \
   grub-efi-amd64-signed shim-signed mtools unzip binutils \
   gparted dosfstools e2fsprogs btrfs-progs xfsprogs ntfs-3g parted

apt-get install -y --no-install-recommends linux-generic-hwe-24.04
# (suffix 22.04 / 24.04 / 26.04 from jammy / noble / resolute)

apt-get install -y calamares-settings-ubuntu-unity
# jammy: apt-get install -y calamares calamares-settings-debian
```

**Vanilla GNOME** desktop stack (replaces `ubuntu-gnome-desktop`) and extra tools:

```shell
apt-get install -y \
   plymouth-themes vanilla-gnome-desktop

apt-get install -y \
   clamav-daemon terminator apt-transport-https curl vim nano less
```

Remove unused packages, then configure locale and networking:

```shell
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
```

---

### 4. Inside the chroot: prepare `/image` (casper, GRUB, manifest)

Still inside the chroot. Create the layout and copy the kernel and initrd:

```shell
mkdir -p /image/{casper,isolinux,install}

cp "/boot/vmlinuz-$(uname -r)" /image/casper/vmlinuz
cp "/boot/initrd.img-$(uname -r)" /image/casper/initrd
```

Memtest86+:

```shell
wget --progress=dot https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip -O /image/install/memtest86.zip
unzip -p /image/install/memtest86.zip memtest64.bin > /image/install/memtest86+.bin
unzip -p /image/install/memtest86.zip memtest64.efi > /image/install/memtest86+.efi
rm -f /image/install/memtest86.zip
```

Marker file for GRUB and `isolinux/grub.cfg`:

```shell
touch /image/ubuntu

cat <<'EOF' > /image/isolinux/grub.cfg
search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=30

menuentry "Try Ubuntu FS without installing" {
   linux /casper/vmlinuz boot=casper nopersistent quiet splash ---
   initrd /casper/initrd
}

menuentry "Check disc for defects" {
   linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
   initrd /casper/initrd
}

grub_platform
if [ "$grub_platform" = "efi" ]; then
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
```

Manifest (remove packages that should not be present on the installed desktop system from the `filesystem.manifest-desktop` copy):

```shell
dpkg-query -W --showformat='${Package} ${Version}\n' | tee /image/casper/filesystem.manifest

cp -v /image/casper/filesystem.manifest /image/casper/filesystem.manifest-desktop

sed -i '/calamares/d' /image/casper/filesystem.manifest-desktop
sed -i '/casper/d' /image/casper/filesystem.manifest-desktop
sed -i '/discover/d' /image/casper/filesystem.manifest-desktop
sed -i '/laptop-detect/d' /image/casper/filesystem.manifest-desktop
sed -i '/os-prober/d' /image/casper/filesystem.manifest-desktop
```

`README.diskdefines`:

```shell
cat <<EOF > /image/README.diskdefines
#define DISKNAME  Ubuntu from scratch
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF
```

Copy the EFI bootloaders, create `efiboot.img`, the GRUB BIOS image, and `md5sum.txt` (run inside the chroot with working directory `/image`):

```shell
cd /image

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
```

---

### 5. Inside the chroot: clean up before exiting

```shell
truncate -s 0 /etc/machine-id

rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl

apt-get clean
rm -rf /tmp/* ~/.bash_history

umount /proc
umount /sys
umount /dev/pts

export HISTSIZE=0
exit
```

---

### 6. On the host: unmount bind mounts

```shell
sudo umount "$HOME/live-ubuntu-from-scratch/chroot/dev"
sudo umount "$HOME/live-ubuntu-from-scratch/chroot/run"
```

### 7. On the host: move `/image`, squashfs, size file, ISO

```shell
cd "$HOME/live-ubuntu-from-scratch"
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

cd image
sudo xorriso \
   -as mkisofs \
   -iso-level 3 \
   -full-iso9660-filenames \
   -J -J -joliet-long \
   -volid "Ubuntu from scratch" \
   -output "../ubuntu-from-scratch.iso" \
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
```

The ISO is written to `$HOME/live-ubuntu-from-scratch/ubuntu-from-scratch.iso`. To copy it to a USB drive, replace `/dev/sdX` with your actual block device:

```shell
sudo dd if=ubuntu-from-scratch.iso of=/dev/sdX status=progress oflag=sync bs=4M
```

---

## Configuration

Use `scripts/build.sh` options or environment variables to choose **`jammy`**, **`noble`**, or **`resolute`**, along with the mirror, kernel options, ISO name, and other overrides. On a TTY you are prompted for the release first, then the kernel type, unless you set them with flags or the environment. Temporary files stay under `scripts/workspace` only until the ISO and checksum files are created, then that folder is removed.

## License

This project is licensed under the **GNU General Public License, version 2.0**. See the [LICENSE](LICENSE) file for the full text.
