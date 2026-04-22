# Build Scripts

## build.sh

The same `build.sh` runs on the **host** (debootstrap, chroot, ISO) and **inside the chroot** when invoked with `--chroot-internal` (do not run that mode yourself; `run_chroot` does it).

Supported releases: **jammy**, **noble**, **resolute** only (HWE suffix **22.04**, **24.04**, or **26.04**). Kernel metapackages are always HWE: `linux-generic-hwe-XX.04` or `linux-lowlatency-hwe-XX.04`, and are installed **with** apt **Recommends** (firmware, microcode, etc.). On a TTY, the script can prompt for the release, then the installer (**Calamares** or **Ubiquity** — Ubiquity only on **jammy**), then the kernel type; or pass `./build.sh --release=… --installer=calamares|ubiquity --kernel=…` for a non-interactive build. Advanced: set `TARGET_KERNEL_PACKAGE` in the environment to pin a metapackage name.

```console
This script builds a bootable Ubuntu ISO image.

Supported commands: setup_host debootstrap run_chroot build_iso

Syntax: ./build.sh [options] [start_cmd] [-] [end_cmd]
  Run from start_cmd to end_cmd
  If start_cmd is omitted, start from the first command
  If end_cmd is omitted, stop after the selected command
  Use a single command to run only that command
  Use '-' by itself to run all commands
```

## How to Customize

Run `./build.sh -` and answer the prompts for release, installer, and kernel, or pass `--release`, `--installer`, and `--kernel` for a scripted run.

**Calamares:** The build installs **only** `calamares` (`--no-install-recommends`). All YAML under **`scripts/calamares/`** is copied into `/etc/calamares/` (`settings.conf`, `modules/`, and optional `i18n/SUPPORTED`). Edit those files to change the installer flow, partitioning defaults, welcome screen, locale behavior, and post-install package removals.

## How to Update

Temporary build files are created under `scripts/workspace/{chroot,image}` during the build. After the ISO plus its SHA-1 and SHA-256 files are created, `scripts/workspace` is deleted automatically to save disk space.
