# Removable Media Image Builder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ubuntu and Pop!_OS removable-media raw `.img` builders cloned from the cloud image scripts, with hybrid firmware default, 8–N GB sizing, dynamic swap, and NoCloud growpart + deploy-time user wizard.

**Architecture:** Copy `build-img.sh` → `build-removable.sh` and `build-popos-img.sh` → `build-popos-removable.sh`, set `UVB_IMAGE_KIND=removable`, then specialize defaults, partition swap math, cloud-init NoCloud seed, and launcher/docs wiring.

**Tech Stack:** Bash build scripts, `parted`/`mkswap`/`mkfs`, GRUB hybrid, `cloud-init` + `cloud-guest-utils`, existing `start-here.sh` dispatcher.

## Global Constraints

- Output is raw `.img` only (no direct device write, no QCOW2/VDI exports).
- Minimum disk size 8 GB; default 16 GB.
- Swap: &lt;16 GB → 2 GiB; ≥16 GB → 4 GiB; always in `/etc/fstab` by UUID.
- Firmware default `hybrid`; UEFI-only still selectable.
- Username CLI matches cloud: `--user-mode=build|deploy` (deploy uses first-boot wizard + NoCloud growpart).
- Separate workspaces/configs: `workspace-removable`, `workspace-popos-removable`, `build-removable.cfg`, `build-popos-removable.cfg`.

---

## File map

| File | Role |
| --- | --- |
| `scripts/build-removable.sh` | Ubuntu removable builder (new) |
| `scripts/build-popos-removable.sh` | Pop!_OS removable builder (new) |
| `start-here.sh` | Add `--output=removable` + deps |
| `README.md`, `scripts/README.md`, `docs/index.md` | Document new output type |

---

### Task 1: Clone Ubuntu cloud builder → removable

**Files:**
- Create: `scripts/build-removable.sh` (copy of `scripts/build-img.sh`)

- [ ] Copy `scripts/build-img.sh` to `scripts/build-removable.sh`
- [ ] Set header comments for removable media purpose
- [ ] Set `UVB_IMAGE_KIND=removable`
- [ ] Rename workspace/config strings: `workspace-img` → `workspace-removable`, `build-img.cfg` → `build-removable.cfg`
- [ ] Commit: `Add build-removable.sh clone of cloud image builder`

### Task 2: Specialize Ubuntu removable behavior

**Files:**
- Modify: `scripts/build-removable.sh`

- [ ] Defaults: `TARGET_FIRMWARE=hybrid`, `TARGET_DISK_SIZE_GB=16`, min size validation `>= 8`
- [ ] In `build_disk_image`: compute `swap_mib` as 2048 if `size_gb < 16` else 4096; log sizes; keep fstab swap line
- [ ] Interactive disk-size prompt: options 8 / 16 / 32 / 64 / custom (min 8); describe dynamic swap
- [ ] Interactive firmware default selection: hybrid
- [ ] Install `cloud-init` + `cloud-guest-utils` when kind is `removable` (same packages as cloud)
- [ ] Bake netplan like non-cloud (`UVB_IMAGE_KIND != cloud` already covers this)
- [ ] Skip cloud serial GRUB; add short removable GRUB timeout config
- [ ] Add `configure_removable_cloud_init()`: NoCloud datasource_list, growpart/resize, network config disabled, seed meta-data/user-data with `users: []`
- [ ] User path: `build` → `create_baked_user` (+ cloud-init default_user cfg for removable); `deploy` → `install_firstboot_user_wizard`
- [ ] Help/summary/generate-config text updated for removable defaults
- [ ] Commit: `Specialize removable builder defaults, swap, and NoCloud setup`

### Task 3: Clone + specialize Pop!_OS removable builder

**Files:**
- Create: `scripts/build-popos-removable.sh`

- [ ] Copy `scripts/build-popos-img.sh` → `scripts/build-popos-removable.sh`
- [ ] Apply the same kind/workspace/config/default/swap/NoCloud/user changes as Ubuntu (Pop naming: `workspace-popos-removable`, `build-popos-removable.cfg`)
- [ ] Commit: `Add Pop!_OS removable media image builder`

### Task 4: Wire launcher and documentation

**Files:**
- Modify: `start-here.sh`, `README.md`, `scripts/README.md`, `docs/index.md` (if applicable)

- [ ] Add `removable` to `--output` parsing, interactive menu (option 4), script map, and deps (`parted dosfstools e2fsprogs rsync`)
- [ ] Document builders, partition rule, examples in README files
- [ ] Commit: `Wire removable output into start-here and docs`

### Task 5: Smoke-check script integrity

- [ ] `bash -n scripts/build-removable.sh scripts/build-popos-removable.sh start-here.sh`
- [ ] `scripts/build-removable.sh --help` and Pop counterpart show removable defaults
- [ ] Confirm no accidental `workspace-img` / `build-img.cfg` leftovers in the new scripts
