# Removable Media Disk Image Builder — Design

**Date:** 2026-07-26  
**Status:** Approved (Approach 1 — clone cloud builders)

## Goal

Produce ready-to-flash raw `.img` files for USB sticks, SD cards, CompactFlash, and similar removable media. When BIOS/UEFI attempts boot from that media, the image boots a full Ubuntu or Pop!_OS system (no live installer). Username handling matches the cloud image builders (`--user-mode=build|deploy`).

## Decisions

| Topic | Choice |
| --- | --- |
| Deliverable | Raw `.img` only (flash later with `dd` / Etcher / Rufus) |
| Distros | Ubuntu + Pop!_OS |
| Approach | Clone `build-img.sh` / `build-popos-img.sh` → removable variants |
| Firmware default | **Hybrid** (BIOS + UEFI); `--firmware=uefi\|hybrid` still available |
| Disk size | Minimum **8** GB, default **16** GB |
| Swap | **&lt; 16 GB → 2 GB**; **≥ 16 GB → 4 GB**; UUID entry in `/etc/fstab` |
| Grow / user at deploy | **growpart** yes; **NoCloud** cloud-init (no cloud datasource wait); deploy user creation via first-boot console wizard |

## Architecture

| Script | Distro | `UVB_IMAGE_KIND` |
| --- | --- | --- |
| `scripts/build-removable.sh` | Ubuntu | `removable` |
| `scripts/build-popos-removable.sh` | Pop!_OS | `removable` |

Pipeline (unchanged stages): `setup_host` → `debootstrap` → `run_chroot` → `build_disk_image`.

Isolated state:

- Workspaces: `workspace-removable/`, `workspace-popos-removable/`
- Configs: `build-removable.cfg`, `build-popos-removable.cfg`
- Output names: `ubuntu-<ver>-<flavor>-removable-amd64-<timestamp>.img` (and Pop!_OS equivalent)

`start-here.sh` gains `--output=removable` and an interactive “Removable media image” choice. Host deps match cloud images (`parted`, `dosfstools`, `e2fsprogs`, `rsync`).

## Partition layout

**Hybrid (default):**

1. BIOS boot — 1 MiB (`bios_grub`)
2. ESP — 512 MB (FAT32)
3. swap — 2 GiB or 4 GiB (size rule above), labeled, UUID in fstab
4. root — remainder (ext4), UUID in fstab

**UEFI-only:** ESP + swap + root (no BIOS boot partition).

`RESUME=none` in initramfs so hibernate is not bound to a generic swap UUID.

## Firmware & boot

- Default `TARGET_FIRMWARE=hybrid` so legacy BIOS USB/card boot and modern UEFI both work.
- GRUB: `i386-pc` when hybrid; always `x86_64-efi` with `--removable` / `--no-nvram` (same as cloud/VM images).
- No cloud serial-console GRUB stanza; use a short visible GRUB timeout suitable for physical media.

## cloud-init / growpart / users

- Always install `cloud-init` + `cloud-guest-utils` (growpart).
- Force `datasource_list: [NoCloud, None]` and ship a minimal seed under `/var/lib/cloud/seed/nocloud/` so first boot does not wait on EC2/Azure/etc.
- Enable growpart + resize_rootfs so flashing a smaller image onto a larger stick expands root.
- Disable cloud-init network config; bake netplan like VM images (NetworkManager or networkd per profile).
- **`--user-mode=build`:** bake username/password (same CLI as cloud); point cloud-init default user at that account when useful.
- **`--user-mode=deploy` (default):** first-boot console wizard creates the account (same *procedure flags* as cloud deploy; local interactive instead of provider metadata).

## Defaults summary

| Setting | Removable default |
| --- | --- |
| Firmware | `hybrid` |
| Disk size | `16` GB (min `8`) |
| Swap | 2 GB if size &lt; 16; else 4 GB |
| User mode | `deploy` |
| Profile / network / alloc | Same as cloud (`desktop`, NM for desktop / networkd for CLI, `truncate`) |
| VM format exports | None |

## Docs

Update root `README.md`, `scripts/README.md`, and `docs/index.md` (if present) to document the new builders and partition rules.

## Out of scope

- Writing directly to `/dev/sdX` during the build
- Shared library refactor of cloud/VM/removable scripts
- MBR-only (non-GPT) layouts
