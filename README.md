# Build your own Ubuntu ISO with vanilla way without `snapd` and more clear

This guide shows how to build a bootable Ubuntu live ISO from a minimal base with **no Snap** (snapd is blocked permanently with APT pinning), and your choice of desktop and installer. Desktop options are **GNOME** (default, via `vanilla-gnome-desktop`), **XFCE** (Xubuntu-equivalent stack — `xfce4` + `xfce4-goodies` + Thunar plugins, `tumbler`, `xfce4-notifyd`/`power-manager`/`screensaver`/`pulseaudio-plugin`/`whiskermenu-plugin`, `catfish`, `menulibre`, `mugshot`, `gigolo`, `galculator`, `xarchiver`, `simple-scan`, `gnome-disk-utility`, `network-manager-gnome`, `blueman`, `pulseaudio`/`pavucontrol`, `system-config-printer`/`cups`, `software-properties-gtk`, `update-manager`/`update-notifier`, `ubuntu-drivers-common`, `synaptic`, `lightdm`/`slick-greeter` — with **no `xubuntu-*` branding packages**, i.e. no `xubuntu-default-settings`, `xubuntu-artwork`, `xubuntu-wallpapers*`, `xubuntu-icon-theme`, or `xubuntu-docs`), and **Minimal** — built on Canonical's own **`ubuntu-server-minimal`** metapackage (the same one the Ubuntu Server installer's "Minimal installation" option uses), installed in the chroot with default Recommends so the target matches the official minimal-server profile rather than a hand-curated guess. The live ISO additionally carries the smallest X stack that lets Calamares render — `xserver-xorg` + `xserver-xorg-input-all` + `xserver-xorg-video-all` + `xinit` + `x11-xserver-utils` + `openbox` + `lightdm` + `lightdm-gtk-greeter` + `accountsservice` + `dbus-x11` + `network-manager-gnome` + `xterm` + `fonts-dejavu-core` — and LightDM auto-logs the casper user `ubuntu` into an Openbox session whose `/etc/xdg/openbox/autostart` launches `nm-applet` and `sudo -E calamares -d` (gated by `/etc/sudoers.d/ubuntu-vanilla-minimal-installer`). After install, Calamares' `packages` module strips that live-only X stack (and `gparted`) from the target, so what's left is exactly what `ubuntu-server-minimal` defines — text console, no DE, no DM. Installer options are **Calamares** (default) or **Ubiquity** (**Ubiquity is supported only on jammy / 22.04 LTS**; use Calamares for noble or resolute). Calamares installs **only the `calamares` package** (with **`--no-install-recommends`** so **`calamares-settings-*`** metapackages are not pulled in as *Recommends*). If `apt` refuses to install `calamares` because your suite requires a flavor settings package as a hard **Depends**, install the smallest satisfying package once to satisfy the resolver, then keep using **`scripts/calamares/`** as the active configuration (or adjust `install_pkg` in `build.sh` accordingly). The full installer UI and jobs come from **`scripts/calamares/`** (`settings.conf`, `modules/*.conf`, branding, and a curated **`i18n/SUPPORTED`**); for the **minimal** desktop, two overlay files (`settings-minimal.conf` and `modules/packages-minimal.conf`) replace the default settings/packages so the `displaymanager` exec step is dropped and the target system has the live X stack stripped. So localization and welcome/locale steps stay lean and avoid common issues with packaged defaults. The live image also adds **Brave Browser** from Brave's official APT repository, **Flatpak** with the **Flathub** remote (both skipped on the **minimal** desktop variant), and core CLI tools (**git**, **wget**, **curl**, **vim**, **nano**, and more). **GParted** and common **filesystem tools** are installed so disk preparation matches what the graphical installer expects.

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
- Host distro based on **Ubuntu or Debian** (the script validates this), with host version **>=** target release (`jammy`, `noble`, or `resolute`) as in the table above.

## Quick start (recommended)

Run from the `scripts` directory. On a normal terminal, if you omit flags, the script can prompt for the Ubuntu release, installer (**Calamares** or **Ubiquity**), kernel type, then **desktop** (the first prompt after kernel), and — when the desktop is GNOME — whether to enable GNOME recommends. The kernel metapackage is always installed **with** apt **Recommends** (so firmware and microcode come along). For fully non-interactive runs, pass `--release`, `--kernel`, and optionally `--installer`, `--desktop`, and `TARGET_GNOME_INSTALL_RECOMMENDS`:

```shell
./build.sh -
./build.sh --release=jammy --kernel=generic -
./build.sh --release=jammy --kernel=generic --installer=ubiquity -
./build.sh --release=noble --kernel=lowlatency --desktop=xfce -
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=noble --kernel=generic --desktop=gnome -
./build.sh --release=noble --kernel=generic --desktop=minimal -
./build.sh --release=resolute --kernel=generic --desktop=minimal -
```

For **Minimal**, the **target system base is `ubuntu-server-minimal`** — the same metapackage Canonical uses for the "Minimal installation" option in the Ubuntu Server installer. It is installed (with default Recommends) in the chroot before squashfs, so the unpacked target inherits the canonical Ubuntu minimal-server profile rather than a hand-picked package list. The live ISO additionally ships only what is strictly needed for Calamares to render: `xserver-xorg`, `xserver-xorg-input-all`, `xserver-xorg-video-all`, `xinit`, `x11-xserver-utils`, `openbox`, `lightdm` + `lightdm-gtk-greeter`, `accountsservice`, `dbus-x11`, `network-manager-gnome`, `xterm`, `fonts-dejavu-core` (all installed with `--no-install-recommends`). LightDM auto-logs the casper live user `ubuntu` into an **Openbox** session, and `/etc/xdg/openbox/autostart` immediately launches `nm-applet` (so users can join WiFi) and `sudo -E calamares -d`. The build also writes `/etc/sudoers.d/ubuntu-vanilla-minimal-installer` so `ubuntu` can run `/usr/bin/calamares` without a password even if casper's own sudoers ever changes. After install, Calamares' `packages` module — overlaid from `scripts/calamares/modules/packages-minimal.conf` — removes that exact live-only X stack, plus `calamares` itself, the casper helpers, and `gparted` (GUI-only) from the target. The minimal-variant `scripts/calamares/settings-minimal.conf` also drops the `displaymanager` exec step so the installed system has no DM. **Brave Browser** and **Flatpak** are skipped for the minimal variant; only the small CLI set (`git`, `vim`, `nano`, `wget`, `less`) is added on top of `ubuntu-server-minimal`.

When the script asks for desktop, the interactive menu is:

```text
Choose desktop environment:
  1) GNOME    Default. vanilla-gnome-desktop (recommends asked next)
  2) XFCE     Lighter. xfce4 + xfce4-goodies + lightdm + slick-greeter
  3) MINIMAL  No desktop on the target (server-friendly); live ISO ships a minimal X stack so Calamares can run
Desktop [1/2/3, Enter=1]:
```

All three options are available on every supported release. **Enter** alone selects **GNOME** (option **1**). You can type numbers or `gnome` / `xfce` / `minimal`.

That runs: host setup -> `debootstrap` -> chroot steps (snapd block, chosen installer + disk tools, selected desktop, Brave, Flatpak, customization) -> ISO creation. While the build runs, temporary files live under a **workspace** directory: by default `<repository-root>/workspace` with `chroot/` and `image/` inside it. If the repo is on a WSL Windows mount (`/mnt/...`) or similar, the script uses `~/.cache/ubuntu-vanilla-build/workspace` instead (debootstrap cannot unpack reliably on DrvFs). You can override the parent path with **`UBUNTU_VANILLA_WORKSPACE`**, which becomes `UBUNTU_VANILLA_WORKSPACE/workspace`. After a successful build, the workspace tree is removed; the ISO and checksum files are written under **`scripts/`** (next to `build.sh`) as **`${TARGET_NAME:-ubuntu}.iso`** (default name **`ubuntu.iso`**) plus **`.sha1`** and **`.sha256`**.

## Terminology

- **Build system** — the machine where you run the build scripts (the host).
- **Live system** — the root filesystem built inside the chroot; this becomes the live ISO contents.
- **Target system** — the installation on disk after the user runs the installer from the live environment.

## Features

### Build behavior

- Single entrypoint: `scripts/build.sh` runs full host + chroot + ISO pipeline.
- Safe cleanup on failure: active mounts and workspace are torn down automatically.
- Non-root friendly runner: host steps use `sudo` when needed.
- Workspace safety for WSL/DrvFs: auto-relocates workspace to Linux-native cache path when needed.
- Deterministic outputs: emits `scripts/${TARGET_NAME:-ubuntu}.iso`, plus `.sha1` and `.sha256`.

### Boot and image layout

- GRUB-only boot stack for both firmware types:
  - UEFI boot via `EFI/boot/*` and `boot/grub/efiboot.img`
  - Legacy BIOS boot via `boot/grub/bios.img`
- No Syslinux/Isolinux dependency in the produced image path.
- Automatically selects the newest installed kernel and initrd for live boot files.
- Includes Memtest86+ binaries for both BIOS and UEFI menu entries.
- Boot menu label is configurable via `GRUB_LIVEBOOT_LABEL`.

### Release and installer support

- Supported suites: `jammy`, `noble`, `resolute`.
- Installer choice:
  - `calamares` (default, all supported suites)
  - `ubiquity` (jammy only, enforced by validation)
- Calamares runs with project-provided config from `scripts/calamares`.
- Manifest trimming is configurable through `TARGET_PACKAGE_REMOVE`.

### Desktop and package profile

- Desktop choice:
  - `gnome` (default, lightweight mode with `--no-install-recommends`)
  - `xfce` — Xubuntu-equivalent package profile (Thunar plugins, tumbler, notifyd, power-manager, screensaver, whiskermenu, catfish, menulibre, mugshot, gigolo, galculator, xarchiver, simple-scan, gnome-disk-utility, NetworkManager applet, blueman, PulseAudio + pavucontrol, system-config-printer + cups, software-properties-gtk, update-manager/notifier, ubuntu-drivers-common, synaptic, lightdm + slick-greeter) **without any `xubuntu-*` branding packages**
  - `minimal` — target base is **`ubuntu-server-minimal`** (Canonical's curated minimal-server metapackage, with default Recommends), so the installed system matches the Ubuntu Server installer's "Minimal installation" choice. The live ISO ships a tiny X stack (`xserver-xorg` + `xserver-xorg-input-all` + `xserver-xorg-video-all`, `xinit`, `x11-xserver-utils`, `openbox`, `lightdm` + `lightdm-gtk-greeter`, `accountsservice`, `dbus-x11`, `network-manager-gnome`, `xterm`, `fonts-dejavu-core`) so Calamares can render. LightDM auto-logs the live `ubuntu` user into Openbox; `/etc/xdg/openbox/autostart` runs `nm-applet` and `sudo -E calamares -d`. After install, Calamares' `packages` module removes the X stack and `gparted` from the target; `settings-minimal.conf` drops the `displaymanager` exec step. Brave and Flatpak are skipped for this variant.
- Optional GNOME recommends mode via `TARGET_GNOME_INSTALL_RECOMMENDS=1`.
- Snap is blocked by APT pinning (`snapd` priority `-1`).
- Preconfigured additions:
  - Brave (official Brave apt source) — skipped on `--desktop=minimal`
  - Flatpak + system Flathub remote — skipped on `--desktop=minimal`
  - CLI tooling (`git`, `vim`, `nano`, `wget`, `less`, etc.)
  - Partition/filesystem tools (`gparted`, `dosfstools`, `btrfs-progs`, `xfsprogs`, `ntfs-3g`, `parted`)
- Removes selected default apps/games and installer slideshow packages to keep the image lean.

## Configuration

Use `scripts/build.sh` options or environment variables to choose **`jammy`**, **`noble`**, or **`resolute`**, along with **`--mirror`**, kernel flavor (**`--kernel=generic|lowlatency`**), installer (**`--installer=calamares|ubiquity`**), desktop (**`--desktop=gnome|xfce|minimal`**), GNOME recommends mode (**`TARGET_GNOME_INSTALL_RECOMMENDS=0|1`**, default `0`), ISO basename (**`TARGET_NAME`**, default **`ubuntu`**), live menu label (**`GRUB_LIVEBOOT_LABEL`**), and workspace parent (**`UBUNTU_VANILLA_WORKSPACE`**). Advanced: set **`TARGET_KERNEL_PACKAGE`** directly if you need to pin a metapackage name. On a TTY the script can prompt for release, installer, kernel, desktop, and (when desktop is GNOME) GNOME recommends, unless you set them with flags or the environment. The build workspace (see Quick start) is removed after **`TARGET_NAME.iso`**, **`.sha1`**, and **`.sha256`** are written under **`scripts/`**.

## License

This project is licensed under the **GNU General Public License, version 2.0**. See the [LICENSE](LICENSE) file for the full text.
