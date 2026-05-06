# Build your own Ubuntu ISO with vanilla way without `snapd` and more clear

This guide presents a method for producing a bootable Ubuntu live ISO from a minimal base while enforcing a strict **no Snap** policy (`snapd` is permanently blocked through APT pinning). It supports two desktop profiles: **GNOME** (default, via `vanilla-gnome-desktop`) and **XFCE** (an Xubuntu-equivalent functional stack based on `xfce4` and `xfce4-goodies`, together with Thunar plugins, core XFCE utilities, networking, audio, printing, update, and session components), explicitly excluding all `xubuntu-*` branding packages (for example, `xubuntu-default-settings`, `xubuntu-artwork`, `xubuntu-wallpapers*`, `xubuntu-icon-theme`, and `xubuntu-docs`). The available installers are **Calamares** (default) and **Ubiquity**, with the important constraint that **Ubiquity is supported only on jammy (22.04 LTS)**; for noble and resolute, Calamares should be used. The Calamares path installs **only `calamares`** with `--no-install-recommends`, thereby preventing automatic installation of `calamares-settings-*` metapackages via Recommends.

If dependency resolution in a given suite requires a flavor settings package as a hard Depends, install the smallest acceptable package once to satisfy the solver, then continue to use **`scripts/calamares/`** as the authoritative configuration source (or adjust `install_pkg` in `build.sh`). In this workflow, the installer interface and job definitions are sourced from **`scripts/calamares/`** (`settings.conf`, `modules/*.conf`, branding assets, and a curated `i18n/SUPPORTED`), which keeps localization and welcome/locale behavior intentionally lean and reduces failure modes associated with packaged defaults. The live image **always** registers the official APT sources for **Brave** (both stable and Origin beta archives), **Librewolf**, and **Mozilla Firefox**, so after installation you can **`apt install`** any of them without adding repositories by hand. Build-time choices only decide **which browsers are pre-installed** in the squashfs (defaults lean toward **Brave stable** only; optional **Librewolf** and **Firefox** via flags, environment variables, or **`-i`** prompts). It always runs the **official Pacstall installer** ([`pacstall.dev/q/install`](https://pacstall.dev/q/install)) so **`pacstall`** is present (same path as `sudo bash -c "$(curl -fsSL https://pacstall.dev/q/install)"` on a desktop — **not** the separate Chaotic PPR / `apt install pacstall` flow). Optionally you can add the **Ubuntu Studio** metapackage set (`TARGET_UBUNTU_STUDIO=1`, **`--ubuntu-studio`**, or **`-i`**). The image also bundles **Flatpak** with the **Flathub** remote, essential CLI tooling (including `git`, `wget`, `curl`, `vim`, and `nano`), and **GParted** plus common filesystem utilities to align disk preparation with graphical installer expectations.

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

Before running it, you need to clone the Git first. After that, Run from the `scripts` directory. On a normal terminal, if you omit flags, the script can prompt for the Ubuntu release, installer (**Calamares** or **Ubiquity**), kernel type, then **desktop** (the first prompt after kernel), and — when the desktop is GNOME — whether to enable GNOME recommends, then **which Brave build to pre-install** (stable, Origin beta, or neither — repositories for both stay on the system). After **Brave**, on a normal terminal (**stdin is a TTY**) and if you did not pass **`TARGET_UBUNTU_STUDIO`** or **`--ubuntu-studio` / `--no-ubuntu-studio`**, the script asks for **Ubuntu Studio** (heavy optional bundle). Browser APT configuration is **always** written. With **`-i` / `--interactive`**, it also asks whether to **pre-install** **Librewolf** and **Firefox** when those are unset. Without **`-i`**, use **`--librewolf`** / **`--firefox`** / **`--no-*`** or **`TARGET_LIBREWOLF`** / **`TARGET_FIREFOX`**. Combine pre-installs (**Brave stable + Librewolf + Firefox**, **`--brave=none`** plus **`--firefox`** only, all skipped, etc.). The kernel metapackage is always installed **with** apt **Recommends** (so firmware and microcode come along). For fully non-interactive runs, pass `--release`, `--kernel`, and optionally `--installer`, `--desktop`, `--brave` / **`--browser`**, **`--librewolf`**, **`--firefox`**, **`--ubuntu-studio`**, and `TARGET_GNOME_INSTALL_RECOMMENDS`:

```shell
./build.sh -
./build.sh --release=jammy --kernel=generic -
./build.sh --release=jammy --kernel=generic --installer=ubiquity -
./build.sh --release=noble --kernel=lowlatency --desktop=xfce -
./build.sh --release=noble --kernel=generic --desktop=gnome --browser=origin-beta -
./build.sh --release=noble --kernel=generic --desktop=gnome --librewolf --firefox -
./build.sh --release=noble --kernel=generic --brave=none --firefox -
./build.sh --release=noble --kernel=generic --desktop=gnome --ubuntu-studio -
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=noble --kernel=generic --desktop=gnome -
```

When the script asks for desktop, the interactive menu is:

```text
Choose desktop environment:
  1) GNOME    Default. vanilla-gnome-desktop (recommends asked next)
  2) XFCE     Lighter. xfce4 + xfce4-goodies + lightdm + slick-greeter
Desktop [1/2, Enter=1]:
```

Both options are available on every supported release. **Enter** alone selects **GNOME** (option **1**). You can type numbers or `gnome` / `xfce`.

When the script asks about **Brave** (after desktop and optional GNOME recommends), the interactive menu is:

```text
Brave Browser
    1) Stable (brave-browser) — release APT repository  [default]
    2) Origin beta (brave-origin-beta)
    3) Skip Brave

  Brave [1/2/3, Enter=1]:
```

**Enter** alone keeps **Brave stable**. You can also type `release`, `stable`, `none`, `skip`, etc.

Next, **Ubuntu Studio** (after Brave, when **`TARGET_UBUNTU_STUDIO`** is not preset):

```text
--- Ubuntu Studio ---

    Large bundle: ubuntustudio-audio/graphics/photography/publishing/video,
    ubuntustudio-wallpapers, ubuntustudio-menu, ubuntu-edu-music.

  Do you want to install Ubuntu Studio packages? (y/N)
```

Default is **no** (**Enter** = skip Ubuntu Studio package install). **`--interactive`** additionally asks about **Librewolf** and **Firefox** when those toggles were not set (**defaults no**).

Reference **manual APT** setups on an already-installed Ubuntu host:

Brave **Origin beta**:

```shell
sudo apt install curl

sudo curl -fsSLo /usr/share/keyrings/brave-browser-beta-archive-keyring.gpg https://brave-browser-apt-beta.s3.brave.com/brave-browser-beta-archive-keyring.gpg

sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-beta.sources https://brave-browser-apt-beta.s3.brave.com/brave-browser.sources

sudo apt update

sudo apt install brave-origin-beta
```

**Librewolf:**

```shell
curl -fsSL https://repo.librewolf.net/pubkey.gpg \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/librewolf.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/librewolf.gpg] https://repo.librewolf.net/ librewolf main" \
  | sudo tee /etc/apt/sources.list.d/librewolf.list

sudo apt update && sudo apt install librewolf
```

**Firefox** (`packages.mozilla.org` APT — pins distro `firefox` to **not** satisfy, so installs come from Mozilla):

```shell
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
  | sudo tee /usr/share/keyrings/packages.mozilla.org.asc > /dev/null

gpg -n -q --import --import-options import-show /usr/share/keyrings/packages.mozilla.org.asc \
  | awk '/pub/{getline; gsub(/^ +| +$/,""); print $0}'

echo "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  | sudo tee /etc/apt/sources.list.d/mozilla.list > /dev/null

cat <<EOF | sudo tee /etc/apt/preferences.d/mozilla
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

sudo apt update && sudo apt install firefox
```

**Pacstall** (official installer — use this rather than Chaotic PPR/`apt install pacstall` if you want the same path as **`build.sh`**):

```shell
sudo bash -c "$(curl -fsSL https://pacstall.dev/q/install)"
```

**Ubuntu Studio** metapackages (optional in **`build.sh`** via **`--ubuntu-studio`** or **`TARGET_UBUNTU_STUDIO=1`**):

```shell
sudo apt install \
  ubuntustudio-audio \
  ubuntustudio-graphics \
  ubuntustudio-photography \
  ubuntustudio-publishing \
  ubuntustudio-video \
  ubuntustudio-wallpapers \
  ubuntustudio-menu \
  ubuntu-edu-music
```

That runs: host setup -> `debootstrap` -> chroot steps (snapd block, chosen installer + disk tools, selected desktop, browser APT sources + selected pre-installs, Pacstall (**`pacstall.dev/q/install`**), optional Ubuntu Studio stack, Flatpak, customization) -> ISO creation. While the build runs, temporary files live under a **workspace** directory: by default `<repository-root>/workspace` with `chroot/` and `image/` inside it. If the repo is on a WSL Windows mount (`/mnt/...`) or similar, the script uses `~/.cache/ubuntu-vanilla-build/workspace` instead (debootstrap cannot unpack reliably on DrvFs). You can override the parent path with **`UBUNTU_VANILLA_WORKSPACE`**, which becomes `UBUNTU_VANILLA_WORKSPACE/workspace`. After a successful build, the workspace tree is removed; the ISO and checksum files are written under **`scripts/`** (next to `build.sh`) as **`${TARGET_NAME:-ubuntu}.iso`** (default name **`ubuntu.iso`**) plus **`.sha1`** and **`.sha256`**.

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
- Optional GNOME recommends mode via `TARGET_GNOME_INSTALL_RECOMMENDS=1`.
- Snap is blocked by APT pinning (`snapd` priority `-1`).
- Preconfigured additions:
  - Browsers — APT **always** wired for **Brave** (release + beta archives), **Librewolf**, and **Mozilla Firefox** (with Ubuntu `firefox` pinning). Build flags only choose **what gets installed** into the image (`brave-browser`, `brave-origin-beta`, `librewolf`, `firefox`, or none of the above).
  - **Pacstall** via the **official** [install script](https://pacstall.dev/q/install) (not Chaotic PPR). **`pacstall`** is always installed in the live rootfs for AUR-style packages.
  - **Ubuntu Studio** (`ubuntustudio-*` metapackages + **`ubuntu-edu-music`**) — optional; prompt on a TTY when unset, or set **`TARGET_UBUNTU_STUDIO`** / **`--ubuntu-studio`**. Unresolved or snap-pulling deps are skipped with a log message.
  - Flatpak + system Flathub remote
  - CLI tooling (`git`, `vim`, `nano`, `wget`, `less`, etc.)
  - Partition/filesystem tools (`gparted`, `dosfstools`, `btrfs-progs`, `xfsprogs`, `ntfs-3g`, `parted`)
- Removes selected default apps/games and installer slideshow packages to keep the image lean.

## Configuration

Use `scripts/build.sh` options or environment variables to choose **`jammy`**, **`noble`**, or **`resolute`**, along with **`--mirror`**, kernel flavor (**`--kernel=generic|lowlatency`**), installer (**`--installer=calamares|ubiquity`**), desktop (**`--desktop=gnome|xfce`**), Brave pre-install (**`--brave=none|release|origin-beta`** or legacy **`--browser=release|origin-beta`** / **`TARGET_BROWSER`**), Librewolf pre-install (**`--librewolf`** / **`--no-librewolf`** or **`TARGET_LIBREWOLF=0|1`**), Firefox pre-install (**`--firefox`** / **`--no-firefox`** or **`TARGET_FIREFOX=0|1`**), Ubuntu Studio (**`--ubuntu-studio`** / **`--no-ubuntu-studio`** or **`TARGET_UBUNTU_STUDIO=0|1`**). Defaults: **Brave stable** pre-installed, Librewolf/Firefox/Ubuntu Studio off (browser repos still configured). Pacstall install is unconditional. **`TARGET_GNOME_INSTALL_RECOMMENDS`**, **`TARGET_NAME`**, **`GRUB_LIVEBOOT_LABEL`**, **`UBUNTU_VANILLA_WORKSPACE`** work as before. Advanced: **`TARGET_KERNEL_PACKAGE`**. On a **TTY**, **`TARGET_UBUNTU_STUDIO`** is resolved with a confirmation when unset (**Ubuntu Studio** section). **`--interactive`** also prompts for Librewolf and Firefox when those are unset (**non-TTY defaults:** Librewolf and Firefox **off**, Ubuntu Studio **off** unless flags/env set). The build workspace (see Quick start) is removed after **`TARGET_NAME.iso`**, **`.sha1`**, and **`.sha256`** are written under **`scripts/`**.

## License

This project is licensed under the **GNU General Public License, version 2.0**. See the [LICENSE](LICENSE) file for the full text.
