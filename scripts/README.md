# Build Scripts Reference

This directory contains the core compilation and configuration scripts used to assemble the custom bootable Ubuntu live ISO.

---

## The build.sh Script

The primary script `build.sh` orchestrates the entire image generation process. It is designed to run in two distinct environments:
1. **On the Host System**: Prepares directories, downloads the base files via `debootstrap`, enters the chroot environment to trigger customization, compresses the system using SquashFS, and packages the result into a bootable ISO.
2. **Inside the Chroot Environment**: Configures packages, blocks Snap packages via APT pinning, sets up browser repositories, and installs desktop environments. This mode is invoked internally with the `--chroot-internal` flag. Do not invoke this flag manually; the `run_chroot` host function handles this automatically.

### Supported Target Releases
Only the following targets are supported:
- **jammy** (Ubuntu 22.04 LTS) — supports the `calamares` and `ubiquity` installers.
- **noble** (Ubuntu 24.04 LTS) — supports the `calamares` installer.
- **resolute** (Ubuntu 26.04 LTS) — supports the `calamares` installer.

By default, the script installs Hardware Enablement (HWE) kernels (`linux-generic-hwe-XX.04` or `linux-lowlatency-hwe-XX.04`) along with their recommended dependencies (firmware, microcode, etc.) to ensure broad compatibility with modern hardware. You can pin a custom metapackage by setting `TARGET_KERNEL_PACKAGE` in the environment.

### Syntax and Modular Execution
Advanced users can execute individual segments of the build pipeline instead of building the entire ISO in one run:

```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

- **Run all stages (default)**: `./build.sh -`
- **Single stage**: Run from `start_cmd` to the end of that command. For example, `./build.sh debootstrap` builds only the base system.
- **Stage range**: Run from `start_cmd` through `end_cmd`. For example, `./build.sh setup_host - run_chroot` runs host preparation, debootstrap, and chroot customization, but stops before compressing the final ISO.

Supported commands:
- `setup_host`: Installs required host build tools (`debootstrap`, `squashfs-tools`, `xorriso`, `grub-pc-bin`, `grub-efi-amd64-bin`, etc.) and sets up workspace permissions.
- `debootstrap`: Pulls the minimal Ubuntu base structure from the mirror into the chroot directory.
- `run_chroot`: Enters the rootfs to disable snapd, set up security policies, and install the chosen desktop profile, browsers, and packages.
- `build_iso`: Compresses the chroot workspace using SquashFS, copies the Casper kernel/initrd boot files, and builds the final hybrid UEFI/BIOS bootable ISO image with GRUB.

---

## Customizing the Live Installer

The Calamares installer configuration files are stored inside the `calamares/` subdirectory. During the `run_chroot` stage, the builder copies all files under `scripts/calamares/` to `/etc/calamares/` inside the target system:

- **settings.conf**: Defines the order of Calamares modules (welcome, partition, users, summary, install, finished) and controls branding properties.
- **modules/**: Contains configuration YAML files for individual installer steps (such as `partition.conf`, `packages.conf`, `locale.conf`, etc.). Modify these files to change installer workflows or pre-configure default options.
- **branding/**: Holds installer assets, stylesheets, welcome slides, and titles.

---

## Workspace Lifecycle and Cleanups

During execution, the builder creates a `workspace/` directory inside the `scripts/` directory to store temporary assets:
- **scripts/workspace/chroot/**: Contains the live system rootfs during build.
- **scripts/workspace/image/**: Stores bootloader files, kernels, and metadata files destined for the ISO filesystem.

On successful compilation, the script automatically deletes the `workspace/` directory to reclaim disk space. If a build fails, you should inspect the chroot directories for logs and then clean up the directory manually using `rm -rf workspace/` or by running `./build.sh -` again (which resets workspace states).
