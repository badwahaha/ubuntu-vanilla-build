# Ubuntu Vanilla ISO Builder (No Snap)

Create a bootable Ubuntu live ISO from a minimal base, with a strict no-Snap policy (`snapd` is pinned with APT priority `-1`).

This project is designed for:

- **Beginners** who want a working custom Ubuntu ISO with simple commands and interactive prompts.
- **Advanced users** who want deterministic output, chroot-level control, tunable package profiles, and full customization capabilities.

## What's New

Recent improvements include:

- **Security Hardening**: Enhanced build pipeline against supply-chain and network attacks with verified package installations
- **Improved Error Handling**: Better error reporting and failure detection - no more silently swallowed failures
- **Code Refactoring**: Extracted shared utilities to eliminate duplicated code patterns for better maintainability
- **Full/Minimal Installation Options**: Calamares installer now offers both Full and Minimal installation types
- **Enhanced Desktop Support**: Added support for KDE Plasma, Cinnamon, Budgie, and improved LXDE with automatic repair
- **Browser Flexibility**: Multiple browser options (Brave, Librewolf, Firefox) with configurable pre-installation
- **Ubuntu Studio Integration**: Optional Ubuntu Studio package set for creative workloads

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

Understanding the build pipeline helps with troubleshooting and customization:

- **Host system**: The machine where you run `scripts/build.sh` (your current Ubuntu/Debian system)
- **Live system**: The rootfs built inside a chroot environment and packed into the ISO (what you boot from the USB)
- **Target system**: The final installed OS after running the installer from the live media

### Build Pipeline

The build process follows these stages:

1. **Host Setup**: Install required tools (debootstrap, squashfs-tools, xorriso) and prepare workspace
2. **Debootstrap**: Create a minimal Ubuntu base system using the chosen release and mirror
3. **Chroot Configuration**: Enter the chroot environment to:
   - Configure APT sources and pinning (including snapd blocking)
   - Install desktop environment and selected packages
   - Configure browser repositories (Brave, Librewolf, Firefox)
   - Install Pacstall and optional extras (Ubuntu Studio, etc.)
4. **Live Image Assembly**: Create the live filesystem structure with Casper integration
5. **SquashFS + ISO Creation**: Compress the filesystem and generate the bootable ISO with GRUB

### Security Features

The build process includes several security hardening measures:

- **Snapd Blocking**: APT pinning prevents snapd installation (Pin-Priority: -1)
- **Verified Package Installation**: Packages are checked for installability and snapd dependencies before installation
- **Supply Chain Protection**: Pacstall installer uses checksum verification (when enabled)
- **Network Security**: All package downloads use HTTPS with verified repositories

## Requirements

### System Requirements

- **Host OS**: Ubuntu/Debian or derivative (automatically validated by the script)
- **Internet Access**: Required for downloading packages from Ubuntu and third-party repositories
- **Disk Space**: Minimum 15-20 GB free space for debootstrap, squashfs, and ISO generation
- **RAM**: 4 GB minimum (8 GB recommended for smoother builds)
- **Permissions**: `sudo` access (script only elevates privileges when necessary)

### Host OS Compatibility

The script supports building on:
- Ubuntu 22.04+ (jammy, noble, resolute)
- Debian 11+ (requires `ubuntu-archive-keyring` package)
- Ubuntu/Debian derivatives (Mint, Pop!_OS, etc.)

**Note**: Use a host OS that is the same release or newer than your target release.

## Quick Start (Beginner Friendly)

### Getting Started in 3 Steps

1. **Clone this repository**:
   ```bash
   git clone <repository-url>
   cd ubuntu-vanilla-build
   ```

2. **Run the build script** (choose one method):
   ```bash
   # Method 1: Using the convenience script from repository root
   ./start-here.sh -

   # Method 2: Directly from scripts directory
   cd scripts/
   ./build.sh -
   ```

The script will interactively prompt you for:
- **Ubuntu Release**: Choose `jammy` (22.04 LTS), `noble` (24.04 LTS), or `resolute` (26.04 LTS)
- **Desktop Environment**: Select from GNOME, XFCE, LXDE, LXQt, MATE, Cinnamon, Budgie, or KDE Plasma
- **Installer Type**: Calamares (recommended, all releases) or Ubiquity (jammy only)
- **Kernel Type**: Generic (standard) or Lowlatency (audio/real-time workloads)
- **Optional Features**: Browser pre-installation, Ubuntu Studio packages, etc.

### Non-Interactive Build

For automation or to skip prompts, provide all required options:

```bash
./build.sh --release=noble --kernel=generic -
```

This builds a Noble (24.04) ISO with GNOME desktop using the default settings.

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

### Basic Options

`scripts/build.sh` supports the following command-line options:

- `--release=jammy|noble|resolute` - Target Ubuntu release
- `--mirror=URL` - Ubuntu package mirror (default: https://archive.ubuntu.com/ubuntu/)
- `--kernel=generic|lowlatency` - Kernel flavor (generic for standard use, lowlatency for audio/real-time)
- `--installer=calamares|ubiquity` - Installer type (Calamares recommended, Ubiquity only for jammy)
- `--desktop=<desktop>` - Desktop environment (gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma)

### Desktop-Specific Options

- `--kde=kde-full|kde-standard|kde-plasma-desktop` - KDE package tier (used with `--desktop=kde-plasma`)
  - `kde-plasma-desktop`: Minimal Plasma desktop
  - `kde-standard`: Standard Plasma with common applications (default)
  - `kde-full`: Complete KDE suite with all applications
- `--mate=full|core` - MATE metapackage choice (used with `--desktop=mate`)
  - `full`: Complete MATE desktop (default)
  - `core`: Lightweight MATE core
- `--mate-extras` / `--no-mate-extras` - Add MATE extras package

### Browser Options

- `--brave=none|release|origin-beta` - Brave browser channel
  - `release`: Stable Brave browser (default)
  - `origin-beta`: Brave Origin beta channel
  - `none`: Skip Brave pre-installation (repo still configured)
- `--librewolf` / `--no-librewolf` - Pre-install Librewolf browser
- `--firefox` / `--no-firefox` - Pre-install Firefox from Mozilla APT
- `--firefox-esr` / `--no-firefox-esr` - Pre-install Firefox ESR from Mozilla PPA
- `--thunderbird` / `--no-thunderbird` - Pre-install Thunderbird from Mozilla PPA

**Note**: Browser repositories are always configured regardless of pre-installation choice. You can install browsers later with `apt install`.

### Additional Options

- `--ubuntu-studio` / `--no-ubuntu-studio` - Include Ubuntu Studio creative packages
- `--browser=release|origin-beta` - Legacy alias for Brave selection (use `--brave` instead)

### Advanced Execution Syntax

For advanced users who want to control specific build stages:

```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

Host commands (run outside chroot):
- `setup_host` - Install dependencies and prepare workspace
- `debootstrap` - Create minimal Ubuntu base system
- `run_chroot` - Execute chroot phase (package installation, configuration)
- `build_iso` - Create SquashFS and generate ISO

Examples:
- `./build.sh -` - Run full pipeline (default)
- `./build.sh setup_host` - Only run host setup
- `./build.sh setup_host - debootstrap` - Run from setup_host through debootstrap
- `./build.sh debootstrap - build_iso` - Run from debootstrap through ISO creation

## Environment Variables

For advanced users who prefer environment variables over command-line options:

### Core Build Variables

- `TARGET_UBUNTU_VERSION` - Ubuntu release codename (jammy, noble, resolute)
- `TARGET_UBUNTU_MIRROR` - Package mirror URL (default: https://archive.ubuntu.com/ubuntu/)
- `TARGET_KERNEL_FLAVOR` - Kernel type (generic, lowlatency)
- `TARGET_KERNEL_PACKAGE` - Advanced: Override kernel metapackage name directly
- `TARGET_INSTALLER` - Installer type (calamares, ubiquity)
- `TARGET_DESKTOP` - Desktop environment slug

### Desktop-Specific Variables

- `TARGET_KDE_PACKAGE` - KDE metapackage when using kde-plasma (kde-full, kde-standard, kde-plasma-desktop)
- `TARGET_MATE_PACKAGE` - MATE metapackage (mate-desktop-environment, mate-desktop-environment-core, or aliases full/core)
- `TARGET_MATE_EXTRAS` - Set to 1 to install mate-desktop-environment-extras with MATE

### Browser Variables

- `TARGET_BRAVE_CHANNEL` - Brave channel (none, release, origin-beta)
- `TARGET_BROWSER` - Legacy alias for Brave (use TARGET_BRAVE_CHANNEL instead)
- `TARGET_LIBREWOLF` - Set to 1 to pre-install Librewolf
- `TARGET_FIREFOX` - Set to 1 to pre-install Firefox
- `TARGET_FIREFOX_ESR` - Set to 1 to pre-install Firefox ESR
- `TARGET_THUNDERBIRD` - Set to 1 to pre-install Thunderbird

### Feature Variables

- `TARGET_UBUNTU_STUDIO` - Set to 1 to include Ubuntu Studio packages
- `TARGET_GNOME_INSTALL_RECOMMENDS` - Set to 1 to install GNOME with recommends (lighter by default)

### Advanced Customization Variables

- `TARGET_PACKAGE_REMOVE` - Space-separated list of packages to remove from target system
- `TARGET_NAME` - Custom output ISO base name (default: ubuntu-<yy>.04-<desktop>-amd64)
- `GRUB_LIVEBOOT_LABEL` - Custom boot menu entry label (default: "Try Ubuntu without installing")
- `UBUNTU_VANILLA_WORKSPACE` - Custom workspace parent directory (useful for WSL)

### Example Usage

```bash
# Using environment variables
TARGET_UBUNTU_VERSION=noble TARGET_DESKTOP=xfce ./build.sh -

# Combining with command-line options
TARGET_DESKTOP=mate TARGET_MATE_EXTRAS=1 ./build.sh --release=noble --kernel=generic -
```

## Workspace and Output Behavior

### Workspace Directory

The build process uses a workspace directory to store temporary files:

- **Default location**: `<repo>/workspace/` (contains `chroot/` and `image/` subdirectories during build)
- **WSL auto-detection**: On WSL DrvFs paths (`/mnt/...`), the workspace is automatically moved to a Linux-native cache path to avoid debootstrap unpack issues
- **Custom location**: Set `UBUNTU_VANILLA_WORKSPACE=/some/path` to use a custom parent directory (actual workspace becomes `/some/path/workspace`)
- **Automatic cleanup**: On successful build, the workspace is automatically removed to save disk space
- **Manual cleanup**: If a build fails, you may need to manually remove the workspace directory

### Output Files

After a successful build, the following files are created in the `scripts/` directory:

- `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso` - The bootable ISO image
- `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha1` - SHA-1 checksum for verification
- `${TARGET_NAME:-ubuntu-<yy>.04-<desktop>-amd64}.iso.sha256` - SHA-256 checksum for verification

The default naming format is `ubuntu-<version>-<desktop>-amd64.iso` (e.g., `ubuntu-24.04-gnome-amd64.iso`).

## Package and Policy Details

### Core Policies

- **No Snap Policy**: `snapd` is blocked via APT pinning (`Pin-Priority: -1`) to ensure a snap-free Ubuntu experience
- **Package Verification**: All packages are checked for installability and snapd dependencies before installation
- **Browser Repositories**: Brave, Librewolf, and Firefox repositories are always configured (even if browsers aren't pre-installed)

### Calamares Installer Configuration

The build uses Calamares configuration from `scripts/calamares/`. Edit YAML files in this directory to modify installer flow, partitioning defaults, welcome screen, locale behavior, and post-install package removals.

### Desktop Environment Profiles

Each desktop environment has a carefully curated package set:

- **GNOME**: Uses `vanilla-gnome-desktop` with optional recommends (lighter by default)
- **XFCE**: Xubuntu-equivalent stack without `xubuntu-*` branding packages; includes `labwc` for Wayland sessions
- **LXDE**: Lightweight stack with `lxde`, `xorg`, `lightdm`, and `slick-greeter` for low-spec systems
- **LXQt**: Upstream-style stack with `lxqt`, `sddm`, and `xorg` (no Lubuntu branding)
- **MATE**: Full or core MATE desktop with `xorg`, `lightdm`, and `slick-greeter`; optional extras available
- **Cinnamon**: Full Cinnamon desktop with `xorg`, `lightdm`, and `slick-greeter`
- **Budgie**: Full Budgie desktop with `xorg`, `lightdm`, and `slick-greeter`
- **KDE Plasma**: Selectable tier (`kde-plasma-desktop`, `kde-standard`, or `kde-full`)

### Special Features

- **Pacstall**: Always installed via official script from [pacstall.dev/q/install](https://pacstall.dev/q/install)
- **Flatpak**: Pre-configured with Flathub repository; GNOME Software plugin included for GNOME desktop
- **Ubuntu Studio**: Optional creative package set (audio, graphics, photography, publishing, video); unavailable dependencies are automatically skipped with logging
- **Kernel Management**: HWE metapackages automatically selected based on release and kernel flavor (unless overridden with `TARGET_KERNEL_PACKAGE`)

### LXDE Repair Mechanism

For LXDE builds, Calamares includes an automatic repair step:
- Triggers when the installed system shows only Openbox instead of LXDE session
- Runs `apt-get update && apt-get install --no-install-recommends lxde` in the target root
- **Requires internet connection during installation** to access package mirrors
- Offline installs skip this step (see troubleshooting section for manual fix)

## Verifying Build Artifacts

After building, verify the integrity of your ISO using the provided checksum files:

```bash
cd scripts/
sha256sum -c ubuntu-24.04-gnome-amd64.iso.sha256
sha1sum -c ubuntu-24.04-gnome-amd64.iso.sha1
```

Replace the filename with your actual ISO name if you used a custom `TARGET_NAME`.

### Testing the ISO

Before deploying, test your ISO in a virtual machine:
- **VirtualBox**: Create a new VM, attach the ISO as optical drive, boot and test live session and installation
- **QEMU/KVM**: Use `qemu-system-x86_64 -cdrom ubuntu-24.04-gnome-amd64.iso -m 4096 -enable-kvm`
- **VMware**: Create a new VM, attach ISO, and test the installation process

### Creating Bootable USB

Use a tool like `dd`, `balenaEtcher`, or `Rufus` (Windows) to create a bootable USB:

```bash
# Using dd (Linux/macOS)
sudo dd if=ubuntu-24.04-gnome-amd64.iso of=/dev/sdX bs=4M status=progress sync
```

**Warning**: Replace `/dev/sdX` with your actual USB device (use `lsblk` to identify).

## Troubleshooting

### Common Issues

- **No interactive prompts in CI/non-TTY environments**: Provide all required options explicitly (`--release`, `--kernel`, and any toggles)
- **Ubiquity installer rejected**: Use `--installer=ubiquity` only with `--release=jammy` (22.04 LTS)
- **Debian host keyring error**: Install `ubuntu-archive-keyring` package: `sudo apt install ubuntu-archive-keyring`
- **Build fails on WSL Windows mount**: Keep repository on Linux filesystem or rely on automatic workspace relocation
- **Missing package in chosen release**: Script logs and skips unavailable/uninstallable packages with warnings
- **LXDE installed system shows only Openbox**: Connect to internet during Calamares installation so the LXDE repair step can reach mirrors, or manually fix after boot (see below)

### Build Failures

If the build fails:
1. Check the error message for specific package or configuration issues
2. Ensure you have sufficient disk space (15-20 GB minimum)
3. Verify internet connectivity and mirror accessibility
4. Try cleaning the workspace manually: `rm -rf scripts/workspace/`
5. Check that your host OS is compatible with the target release

### LXDE Openbox-Only Issue

If you install an LXDE ISO while offline and the system boots to Openbox only:

**After you get internet:**
1. Boot into the installed system and select the Openbox session
2. Open a terminal and run:
   ```bash
   sudo apt update
   sudo apt install --no-install-recommends lxde
   ```
3. Log out or reboot
4. At the login screen, select **LXDE Session**, then log in

**Panel configuration fix:**
If the taskbar/panel looks wrong or missing:
- Right-click the LXDE panel → Edit Panel → Panel Preferences
- Remove the **Desktop Pager** and **Desktop Spacer** applets

### Advanced Debugging

For detailed debugging, you can run individual build stages:

```bash
# Run only host setup to check dependencies
./build.sh setup_host

# Run debootstrap stage to check base system creation
./build.sh debootstrap

# Run chroot stage to check package installation
./build.sh run_chroot
```

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

## Advanced Customization

### Modifying Calamares Configuration

For deep customization of the installer experience, edit the YAML files in `scripts/calamares/`:

- `settings.conf` - Main Calamares configuration and module sequence
- `modules/` - Individual module configurations (partitioning, users, packages, etc.)
- `branding/` - Visual branding and slideshow content
- `i18n/SUPPORTED` - Supported locales

### Adding Custom Packages

To add custom packages to your build, modify the `customize_image()` function in `scripts/build.sh`. Look for the desktop-specific sections and add your packages to the appropriate `apt-get install` commands.

### Creating Custom Desktop Profiles

To add a new desktop environment variant:
1. Add the desktop name to the validation in `normalize_desktop_variant()`
2. Add installation logic in the `customize_image()` function under a new case statement
3. Update the help text in `host_help()` to document the new option

## Contributing

Contributions are welcome! Areas for contribution:
- Additional desktop environment profiles
- Package selection optimizations
- Documentation improvements
- Bug fixes and error handling enhancements

## License

Licensed under **GNU General Public License v2.0**. See `LICENSE`.
