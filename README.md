# Build your own Ubuntu ISO with vanilla way without `snapd` and more clear

This guide shows how to build a bootable Ubuntu live ISO from a minimal base with **no Snap** (snapd is blocked permanently with APT pinning), and your choice of desktop and installer. Desktop options are **GNOME** (default, via `vanilla-gnome-desktop`), **XFCE** (`xfce4` + `xfce4-goodies` + `lightdm`/`slick-greeter`), and **Cosmic** (`cosmic-session` from PPA `ppa:hepp3n/cosmic-epoch`; **supported only on `noble` and `resolute`**, not on jammy). Installer options are **Calamares** (default) or **Ubiquity** (**Ubiquity is supported only on jammy / 22.04 LTS**; use Calamares for noble or resolute). Calamares installs **only the `calamares` package** (with **`--no-install-recommends`** so **`calamares-settings-*`** metapackages are not pulled in as *Recommends*). If `apt` refuses to install `calamares` because your suite requires a flavor settings package as a hard **Depends**, install the smallest satisfying package once to satisfy the resolver, then keep using **`scripts/calamares/`** as the active configuration (or adjust `install_pkg` in `build.sh` accordingly). The full installer UI and jobs come from **`scripts/calamares/`** (`settings.conf`, `modules/*.conf`, branding, and a curated **`i18n/SUPPORTED`**) so localization and welcome/locale steps stay lean and avoid common issues with packaged defaults. The live image also adds **Brave Browser** from Brave’s official APT repository, **Flatpak** with the **Flathub** remote, and core CLI tools (**git**, **wget**, **curl**, **vim**, **nano**, and more). **GParted** and common **filesystem tools** are installed so disk preparation matches what the graphical installer expects.

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

Run from the `scripts` directory. On a normal terminal, if you omit flags, the script can prompt for the Ubuntu release, installer (**Calamares** or **Ubiquity**), kernel type, desktop (**gnome**, **xfce**, or **cosmic** on noble/resolute), whether to enable GNOME recommends, and (for Cosmic) whether to install `cosmic-session` with or without apt **Recommends**. The kernel metapackage is always installed **with** apt **Recommends** (so firmware and microcode come along). For fully non-interactive runs, pass `--release`, `--kernel`, and optionally `--installer`, `--desktop`, `TARGET_GNOME_INSTALL_RECOMMENDS`, and `TARGET_COSMIC_INSTALL_RECOMMENDS` when using Cosmic:

```shell
./build.sh -
./build.sh --release=jammy --kernel=generic -
./build.sh --release=jammy --kernel=generic --installer=ubiquity -
./build.sh --release=noble --kernel=lowlatency --desktop=xfce -
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=noble --kernel=generic --desktop=gnome -
./build.sh --release=noble --kernel=generic --desktop=cosmic -
TARGET_COSMIC_INSTALL_RECOMMENDS=1 ./build.sh --release=resolute --kernel=generic --desktop=cosmic -
```

For **Cosmic**, the build adds the PPA (`add-apt-repository ppa:hepp3n/cosmic-epoch -y` equivalent), then installs `cosmic-session`. By default **`TARGET_COSMIC_INSTALL_RECOMMENDS=0`**, which runs `apt install --no-install-recommends cosmic-session`. Set **`TARGET_COSMIC_INSTALL_RECOMMENDS=1`** for a full install *with* recommends (like `apt install cosmic-session` with default recommends).

When the script asks for desktop, the interactive menu is:

```text
Choose desktop environment:
  1) GNOME (default, recommended for most users)
  2) XFCE (lighter and faster)
  3) COSMIC (only shown on noble or resolute)
Desktop [1/2/3, Enter=1]:
```

On **jammy**, only options **1** and **2** are listed. You can type `1`/`2`/`3` (or `gnome`/`xfce`/`cosmic`). Press **Enter** to accept **GNOME**.

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
  - `xfce`
  - `cosmic` — PPA `ppa:hepp3n/cosmic-epoch`, then `cosmic-session` (noble and resolute only; validation rejects jammy)
- Optional GNOME recommends mode via `TARGET_GNOME_INSTALL_RECOMMENDS=1`.
- Optional Cosmic install mode via `TARGET_COSMIC_INSTALL_RECOMMENDS=1` (with recommends); default `0` uses `--no-install-recommends` for `cosmic-session`.
- Snap is blocked by APT pinning (`snapd` priority `-1`).
- Preconfigured additions:
  - Brave (official Brave apt source)
  - Flatpak + system Flathub remote
  - CLI tooling (`git`, `vim`, `nano`, `wget`, `less`, etc.)
  - Partition/filesystem tools (`gparted`, `dosfstools`, `btrfs-progs`, `xfsprogs`, `ntfs-3g`, `parted`)
- Removes selected default apps/games and installer slideshow packages to keep the image lean.

## Configuration

Use `scripts/build.sh` options or environment variables to choose **`jammy`**, **`noble`**, or **`resolute`**, along with **`--mirror`**, kernel flavor (**`--kernel=generic|lowlatency`**), installer (**`--installer=calamares|ubiquity`**), desktop (**`--desktop=gnome|xfce|cosmic`**; **cosmic** is only valid with **noble** or **resolute**), GNOME recommends mode (**`TARGET_GNOME_INSTALL_RECOMMENDS=0|1`**, default `0`), Cosmic recommends mode for **`cosmic-session`** (**`TARGET_COSMIC_INSTALL_RECOMMENDS=0|1`**, default `0`), ISO basename (**`TARGET_NAME`**, default **`ubuntu`**), live menu label (**`GRUB_LIVEBOOT_LABEL`**), and workspace parent (**`UBUNTU_VANILLA_WORKSPACE`**). Advanced: set **`TARGET_KERNEL_PACKAGE`** directly if you need to pin a metapackage name. On a TTY the script can prompt for release, installer, kernel, desktop, GNOME recommends, and (when desktop is Cosmic) Cosmic recommends unless you set them with flags or the environment. The build workspace (see Quick start) is removed after **`TARGET_NAME.iso`**, **`.sha1`**, and **`.sha256`** are written under **`scripts/`**.

## License

This project is licensed under the **GNU General Public License, version 2.0**. See the [LICENSE](LICENSE) file for the full text.
