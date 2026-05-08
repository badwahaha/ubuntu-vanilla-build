# Ubuntu Vanilla ISO Builder (No Snap)

Create a bootable Ubuntu live ISO from a minimal base, with a strict no-Snap policy (`snapd` is pinned with APT priority `-1`).

This project is designed for:

- **Beginners** who want a working custom Ubuntu ISO with simple commands.
- **Advanced users** who want deterministic output, chroot-level control, and tunable package profiles.

## What This Build Produces

- A bootable ISO with **GRUB for UEFI and BIOS**.
- Desktop choices:
  - `gnome` (default, based on `vanilla-gnome-desktop`)
  - `xfce` (Xubuntu-like functional stack, without `xubuntu-*` branding packages; includes `labwc` for Wayland)
  - `lxde` (lightweight LXDE stack with `lightdm` and `slick-greeter`, for low-spec systems; see **LXDE + Calamares** below if the installed system only offers Openbox until you go online)
  - `lxqt` (LXQt via `lxqt` + `sddm` + `xorg`; no `lubuntu-desktop` / Lubuntu branding metapackages)
  - `mate` (`mate-desktop-environment` or lighter `mate-desktop-environment-core`, plus optional `mate-desktop-environment-extras`; `lightdm` + `slick-greeter`)
  - `cinnamon` (`cinnamon-desktop-environment` with `lightdm` and `slick-greeter`)
  - `budgie` (`budgie-desktop-environment` with `lightdm` and `slick-greeter`)
  - `kde-plasma` (KDE Plasma with selectable APT metapackage: `kde-full`, `kde-standard`, or `kde-plasma-desktop`)
  - Additional variants can be added by extending desktop install logic in `scripts/build.sh`.
- Installer choices:
  - `calamares` (default, all supported releases)
  - `ubiquity` (**jammy only**)
- Browser repositories always configured for:
  - Brave (stable + Origin beta)
  - Librewolf
  - Mozilla Firefox (`packages.mozilla.org` with pinning)
- Optional pre-installs: Brave channel, Librewolf, Firefox, Ubuntu Studio package set.
- Always installs Pacstall through the official installer: [pacstall.dev/q/install](https://pacstall.dev/q/install).
- Outputs in `scripts/`:
  - `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso`
  - `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha1`
  - `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha256`

## Supported Ubuntu Targets

Only these target releases are supported:

| Codename | Version | HWE suffix |
| --- | --- | --- |
| `jammy` | 22.04 LTS | `-hwe-22.04` |
| `noble` | 24.04 LTS | `-hwe-24.04` |
| `resolute` | 26.04 LTS | `-hwe-26.04` |

Use a host OS that is the same release as the target or newer.

## Build Concepts

- **Host system**: where you run `scripts/build.sh`.
- **Live system**: rootfs built inside chroot and packed into the ISO.
- **Target system**: installed OS after running installer from live media.

Pipeline:

1. Host setup
2. `debootstrap` base system
3. Chroot configuration + package installation
4. Live image assembly
5. SquashFS + ISO creation (`xorriso`)

## Requirements

- Host distro: Ubuntu/Debian or derivative (validated by script).
- Internet access to Ubuntu and third-party package sources.
- Sufficient disk space/RAM for debootstrap + squashfs + ISO generation.
- `sudo` access (script elevates only where needed).

## Quick Start (Beginner Friendly)

1. Clone this repository.
2. Open terminal and go to `scripts/`.
3. Run build:

```bash
./build.sh -
```

If you prefer fewer prompts, provide required non-interactive arguments:

```bash
./build.sh --release=noble --kernel=generic -
```

### Common Examples

```bash
# Jammy + generic kernel + defaults
./build.sh --release=jammy --kernel=generic -

# Jammy + Ubiquity installer (jammy only)
./build.sh --release=jammy --kernel=generic --installer=ubiquity -

# Jammy + Calamares + XFCE
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=xfce -

# Jammy + Calamares + LXDE (lightweight desktop)
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=lxde -

# Jammy + Calamares + LXQt (SDDM, no Lubuntu branding stack)
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=lxqt -

# Jammy + Calamares + MATE
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=mate -

# Jammy + MATE core + extras (non-interactive)
./build.sh --release=jammy --kernel=generic --desktop=mate --mate=core --mate-extras -

# Jammy + Calamares + Cinnamon
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=cinnamon -

# Jammy + Calamares + Budgie
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=budgie -

# Jammy + KDE Plasma desktop using the standard package set
./build.sh --release=jammy --kernel=generic --desktop=kde-plasma --kde=kde-standard -

# Noble + KDE Plasma desktop with full KDE package set
./build.sh --release=noble --kernel=generic --desktop=kde-plasma --kde=kde-full -

# Resolute + KDE Plasma desktop with minimal package set
./build.sh --release=resolute --kernel=generic --desktop=kde-plasma --kde=kde-plasma-desktop -

# Jammy + GNOME + Librewolf and Firefox preinstalled
./build.sh --release=jammy --kernel=generic --desktop=gnome --librewolf --firefox -

# Noble + XFCE + lowlatency kernel
./build.sh --release=noble --kernel=lowlatency --desktop=xfce -

# Noble + GNOME + Brave Origin beta preinstalled
./build.sh --release=noble --kernel=generic --desktop=gnome --brave=origin-beta -

# Noble + no Brave, but preinstall Firefox
./build.sh --release=noble --kernel=generic --brave=none --firefox -

# Noble + GNOME with recommends enabled
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=noble --kernel=generic --desktop=gnome -

# Noble + GNOME + Ubuntu Studio extras
./build.sh --release=noble --kernel=generic --desktop=gnome --ubuntu-studio -

# Noble + custom mirror
./build.sh --release=noble --kernel=generic --mirror=http://archive.ubuntu.com/ubuntu/ -

# Resolute + generic kernel + defaults
./build.sh --release=resolute --kernel=generic -

# Resolute + XFCE + lowlatency kernel
./build.sh --release=resolute --kernel=lowlatency --desktop=xfce -

# Resolute + GNOME + Brave skipped + Librewolf preinstalled
./build.sh --release=resolute --kernel=generic --desktop=gnome --brave=none --librewolf -

# Resolute + GNOME + Brave Origin beta + Firefox preinstalled
./build.sh --release=resolute --kernel=generic --desktop=gnome --brave=origin-beta --firefox -

# Resolute + GNOME with recommends enabled
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=resolute --kernel=generic --desktop=gnome -
```

## Interactive Prompts

The script is interactive by default on a TTY when required values are missing (no `-i`/`--interactive` flag is used).

When running with a TTY and values are not pre-set, script can ask for:

- Release (`jammy`/`noble`/`resolute`)
- Installer (`calamares`/`ubiquity`, with release validation)
- Kernel flavor (`generic`/`lowlatency`)
- Desktop (`gnome`/`xfce`/`lxde`/`lxqt`/`mate`/`cinnamon`/`budgie`/`kde-plasma`)
- KDE package tier when desktop is `kde-plasma` (`kde-standard`/`kde-plasma-desktop`/`kde-full`)
- MATE metapackage (`mate-desktop-environment` vs `mate-desktop-environment-core`) and optional `mate-desktop-environment-extras` when desktop is `mate`
- GNOME recommends toggle (GNOME only)
- Brave channel (`release`/`origin-beta`/`none`)
- Librewolf preinstall toggle
- Firefox preinstall toggle
- Ubuntu Studio package set toggle

Defaults when not explicitly set:

- Installer: `calamares`
- Desktop: `gnome`
- Brave channel: `release`
- Librewolf: disabled
- Firefox: disabled
- Ubuntu Studio: disabled
- GNOME recommends: disabled
- MATE (when selected interactively): full metapackage by default; extras off unless you choose them

## Command-Line Options

`scripts/build.sh` supports:

- `--release=jammy|noble|resolute`
- `--mirror=URL`
- `--kernel=generic|lowlatency`
- `--installer=calamares|ubiquity`
- `--desktop=<desktop>` (currently implemented: `gnome`, `xfce`, `lxde`, `lxqt`, `mate`, `cinnamon`, `budgie`, `kde-plasma`)
- `--kde=kde-full|kde-standard|kde-plasma-desktop` (used with `--desktop=kde-plasma`; default `kde-standard`)
- `--mate=full|core|mate-desktop-environment|mate-desktop-environment-core` (used with `--desktop=mate`; default full metapackage)
- `--mate-extras` / `--no-mate-extras` (optional `mate-desktop-environment-extras` with `--desktop=mate`)
- `--brave=none|release|origin-beta`
- `--browser=release|origin-beta` (legacy alias for Brave selection)
- `--librewolf` / `--no-librewolf`
- `--firefox` / `--no-firefox`
- `--ubuntu-studio` / `--no-ubuntu-studio`

Advanced execution syntax:

```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

Host commands are:

- `setup_host`
- `debootstrap`
- `run_chroot`
- `build_iso`

`-` means run the full host pipeline.

## Environment Variables

Main variables:

- `TARGET_UBUNTU_VERSION`
- `TARGET_UBUNTU_MIRROR`
- `TARGET_KERNEL_FLAVOR`
- `TARGET_KERNEL_PACKAGE` (advanced override)
- `TARGET_INSTALLER`
- `TARGET_DESKTOP`
- `TARGET_KDE_PACKAGE` (`kde-full|kde-standard|kde-plasma-desktop`, for `TARGET_DESKTOP=kde-plasma`)
- `TARGET_MATE_PACKAGE` (`mate-desktop-environment|mate-desktop-environment-core`, or aliases `full|core`, for `TARGET_DESKTOP=mate`)
- `TARGET_MATE_EXTRAS` (`0|1`, also install `mate-desktop-environment-extras` when `TARGET_DESKTOP=mate`)
- `TARGET_BRAVE_CHANNEL`
- `TARGET_BROWSER` (legacy Brave alias if `TARGET_BRAVE_CHANNEL` unset)
- `TARGET_LIBREWOLF=0|1`
- `TARGET_FIREFOX=0|1`
- `TARGET_UBUNTU_STUDIO=0|1`
- `TARGET_GNOME_INSTALL_RECOMMENDS=0|1`
- `TARGET_PACKAGE_REMOVE` (manifest trimming)
- `TARGET_NAME` (output ISO base name override; default: `ubuntu-<yy>.04-<desktop>-amd64`)
- `GRUB_LIVEBOOT_LABEL` (boot menu entry label)
- `UBUNTU_VANILLA_WORKSPACE` (workspace parent directory)

## Workspace and Output Behavior

- Default workspace: `<repo>/workspace` (contains `chroot/` and `image/` while building).
- On WSL DrvFs paths (`/mnt/...`), workspace is auto-moved to a Linux-native cache path to avoid debootstrap unpack issues.
- If `UBUNTU_VANILLA_WORKSPACE=/some/path`, actual workspace becomes `/some/path/workspace`.
- On success, workspace is cleaned automatically.
- Final ISO + checksum files remain in `scripts/`.

## Package and Policy Details

- **No Snap**: `snapd` blocked via APT pinning (`Pin-Priority: -1`).
- **Calamares**: project config from `scripts/calamares` is used. For the **LXDE** desktop variant, Calamares runs an extra step (`shellprocess@lxde-repair`) when the live image looks like an Openbox-based LXDE build but the **LXDE** session is missing on the target (for example you only see **Openbox** at the login session menu after install). That step runs `apt-get update` and then `apt-get install --no-install-recommends lxde` inside the target root. **It only applies `lxde` when the machine has working network during install** (offline installs skip the repair and the installer still completes). If you installed offline, see **LXDE ISO bug (Openbox-only until you’re online)** below.
- **Kernel**: HWE metapackage resolved by release + selected flavor (unless `TARGET_KERNEL_PACKAGE` is explicitly provided).
- **XFCE profile**: installs functional XFCE stack and utilities while excluding `xubuntu-*` branding packages; includes `labwc` for optional Wayland sessions.
- **LXDE profile**: installs the `lxde` metapackage with `xorg`, `lightdm`, and `slick-greeter`.
- **LXDE + Calamares**: the repair step above is the supported workaround when the unpacked system does not get a full **LXDE** session; it requires **Internet during Calamares** to run `apt` successfully.
- **LXQt profile**: installs `lxqt`, `sddm`, and `xorg` (upstream-style stack without `lubuntu-desktop` / Lubuntu branding metapackages).
- **MATE profile**: installs `mate-desktop-environment` or `mate-desktop-environment-core` (your choice), with `xorg`, `lightdm`, and `slick-greeter`. Optionally adds `mate-desktop-environment-extras` when enabled (`TARGET_MATE_EXTRAS=1`, `--mate-extras`, or the interactive prompt).
- **Cinnamon profile**: installs `cinnamon-desktop-environment` with `xorg`, `lightdm`, and `slick-greeter`.
- **Budgie profile**: installs `budgie-desktop-environment` with `xorg`, `lightdm`, and `slick-greeter`.
- **KDE profile**: installs one selected KDE metapackage (`kde-full`, `kde-standard`, or `kde-plasma-desktop`).
- **Browsers**: repositories are always configured; flags only control pre-install into live filesystem.
- **Pacstall**: installed unconditionally via official script.
- **Ubuntu Studio**: optional heavy package set; unavailable/snap-pulling dependencies are skipped with logs.

## Verifying Build Artifacts

From `scripts/`:

```bash
sha256sum -c "${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha256"
sha1sum -c "${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha1"
```

## Troubleshooting

- **No prompt in CI/non-TTY**: provide required options explicitly (`--release`, `--kernel`, and any toggles).
- **Ubiquity rejected**: use `--installer=ubiquity` only with `--release=jammy`.
- **Debian host keyring error**: install `ubuntu-archive-keyring`.
- **Build on WSL Windows mount fails/unreliable**: keep repo on Linux filesystem or rely on workspace auto-relocation.
- **Missing package in chosen release**: script logs and skips unavailable/uninstallable packages where applicable.
- **LXDE installed system shows only Openbox**: connect during Calamares so the LXDE repair step can reach the mirrors, or after boot run `sudo apt update && sudo apt install lxde` (see **Package and Policy Details** → Calamares).

## LXDE ISO bug (Openbox-only until you’re online)
If you install an **LXDE** ISO while the installer machine is **offline**, the system may end up booting to **Openbox only** (instead of an LXDE session).

Fix after you get internet:
1. Boot into the installed system and enter the **Openbox** session.
2. Open a terminal and run:
   - `sudo apt update`
   - `sudo apt install --no-install-recommends lxde`
3. Log out (or reboot).
4. At the login screen, select **LXDE Session**, then log in again.

If the taskbar/right-side panel looks wrong or missing:
- In the LXDE panel, remove the applets **Desktop Pager** and **Desktop Spacer** (right-click the panel -> Edit Panel/Panel Preferences -> delete those applets).

## License

Licensed under **GNU General Public License v2.0**. See `LICENSE`.
