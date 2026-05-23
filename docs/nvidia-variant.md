# NVIDIA variant — plan & migration

Status: **Part A built and verified locally on F44** (branch `nvidia-variant`, two
commits, not yet pushed). What remains: verify GPU + sway on the actual 1070, then
build/sign the stepping-stone images and migrate the workstation (Part B).

## Why

A second machine (the workstation) is still on the **retired ublue-os
`sericea-nvidia` spin at Fedora 41** — the same dead-base situation the laptop was in
when this project started. It needs to move onto this repo's image, with NVIDIA
support, eventually at Fedora 44.

The laptop has already completed the journey (ublue F42 → this repo's image → F43 → F44,
on the signed `ostree-image-signed` transport). The workstation is one major further
back **and** needs the NVIDIA driver, which the base image does not build.

## Decisions

- **GPU:** GTX 1070 = **Pascal** → **`akmod-nvidia-580xx`** (RPMfusion's 580 *legacy*
  branch). NVIDIA's 580 series is the last to support Maxwell/Pascal/Volta. RPMfusion's
  mainline `akmod-nvidia` is now **595**, which dropped all pre-Turing GPUs — so mainline
  (and `akmod-nvidia-open`, which needs Turing+ anyway) will **not** drive a 1070. This
  reverses the original "use mainline akmod-nvidia" plan; see Pascal note below.
- **CUDA:** included. The package carries the branch infix:
  `xorg-x11-drv-nvidia-580xx-cuda` (mainline/open use `xorg-x11-drv-nvidia-cuda`).
- **VAAPI:** `libva-nvidia-driver` (NOT `nvidia-vaapi-driver` — the project/package was
  renamed). Branch-independent.
- **Delivery:** a **separate image**, `ghcr.io/fbunt/sericea-main-nvidia`, not a tag on
  the base image.
- **Driver branch is a build arg** (`NVIDIA_DRIVER`, the `akmod-<value>` suffix), with
  branch-aware CUDA naming, so a future Turing+/Blackwell card is a one-line swap to
  `nvidia` or `nvidia-open`. A single image can only carry one branch (they provide the
  same `nvidia.ko`); "supporting both" means two parameterized images.
- **Base now publishes a Fedora-major tag** (`sericea-main:44`) so the NVIDIA `FROM` and
  the stepping-stone rebases can pin a version. Previously only `:latest`/`:YYYYMMDD`
  existed.

## Part A — the NVIDIA layer (built; files on `nvidia-variant`)

Layered on the base image so it inherits the whole sway / RPMfusion / signing / lint
setup and only adds GPU bits.

- **`Containerfile.nvidia`** — `FROM ghcr.io/fbunt/sericea-main:${SOURCE_TAG}`,
  `ARG NVIDIA_DRIVER="nvidia-580xx"`. Runs `build-nvidia.sh` then `ostree container commit`.
- **`build-nvidia.sh`** — installs + compiles the kmod at build time:
  - Installs `akmod-${NVIDIA_DRIVER}`, the branch CUDA package, `libva-nvidia-driver`,
    and `kernel-devel` **matching the baked kernel exactly** (`rpm -q kernel`).
  - **The akmod-in-container gotcha (the finicky part, now solved):**
    akmod-nvidia's ostree `%post` runs `akmods-ostree-post`, which builds the kmod by
    calling `akmodsbuild` **as root**. `akmodsbuild`'s "don't misuse me as root" guard is
    literally `if [[ -w /var ]]` — it assumes the rpm-ostree *compose* sandbox where
    `/var` is read-only. In a `podman build` + `rpm-ostree install`, `/var` **is**
    writable, so the guard trips, the `%post` returns non-zero, and the whole transaction
    aborts (`Error -1 running transaction`). ublue avoids this by building on a *non-ostree*
    base (the hook short-circuits) and running `akmods` manually. We do the equivalent on
    our ostree base: install `akmods` first, replace `/usr/sbin/akmods-ostree-post` with
    an `exit 0` stub, install the driver, then build the module ourselves as the
    unprivileged `akmods` user (`runuser -u akmods -- akmodsbuild …`) and `rpm2cpio | cpio`
    it into `/` — exactly what the compose hook would have done.
  - nouveau blacklist (`/usr/lib/modprobe.d/blacklist-nouveau.conf`) + kargs
    (`/usr/lib/bootc/kargs.d/00-nvidia.toml`: blacklist nouveau, `nvidia-drm.modeset=1`).
  - sway/wlroots env drop-in (`/usr/lib/environment.d/90-nvidia-wayland.conf`,
    currently just `WLR_NO_HARDWARE_CURSORS=1`) — **still to confirm on hardware**, incl.
    whether sway needs `--unsupported-gpu`.
  - Widens the inherited `policy.json` + `registries.d` to also trust
    `ghcr.io/fbunt/sericea-main-nvidia` (same cosign key, already on disk).
- **`check-build-nvidia.sh`** — asserts `nvidia.ko` was produced for the baked kernel,
  the akmod + CUDA packages are installed, policy trusts both repos, `bootc container lint`.
- **`build-nvidia.yml`** — runs after the base publishes, `FROM` the published base tag,
  reuses rechunk + cosign signing, gated on the base digest changing; `workflow_dispatch`
  inputs `fedora_version` (42/43/44) and `nvidia_driver` for the stepping stones.

Local verification (F44, kernel `7.0.9-205.fc44`): `akmod-nvidia-580xx 580.159.03` →
`nvidia.ko` (vermagic matches the kernel), `check-build-nvidia` passes, policy trusts
both repos. Build command:
```bash
podman build -f Containerfile.nvidia --build-arg SOURCE_TAG=latest -t local-sericea-main-nvidia .
```
(`SOURCE_TAG=latest` because `:44` only exists once the updated `build.yml` runs on `main`.)

## Part A.5 — verify GPU + sway on the actual 1070 first

Before building the throwaway 42/43 images, confirm the GPU bits work on real hardware
(GPU correctness is identical regardless of how you reach F44; this de-risks early). The
F41 deployment is already pinned, so this is a throwaway test you roll back from.

`podman build` here runs in the user's rootless storage, but `rpm-ostree` (root) reads
*root's* storage — so move the image over first rather than rebuilding as root:
```bash
podman save localhost/local-sericea-main-nvidia:latest | sudo podman load
sudo rpm-ostree rebase ostree-unverified-image:containers-storage:localhost/local-sericea-main-nvidia:latest
systemctl reboot
```
After reboot, verify: `nvidia-smi` lists the 1070, `cat /proc/driver/nvidia/version`,
`lsmod | grep nvidia`, and sway starts and renders (note whether `--unsupported-gpu` /
which `WLR_*` are actually needed). Then roll back to pinned F41:
```bash
sudo rpm-ostree rollback && systemctl reboot
```
Fold any sway/WLR findings back into `build-nvidia.sh`.

## Part B — workstation migration (stepping stones)

Chosen path: step one major at a time (41→42→43→44), verifying boot + GPU + sway at each
stop, because the first hop is a cross-vendor change (ublue → ours) and three majors of
`/etc` drift is the real risk (a rebase is a rollback-able atomic swap, so the driver
isn't the cross-version risk). Reality the original plan missed: the repo only ever built
the *current* Fedora, so **the 42/43 base images don't exist** and must be built too.

1. Build + sign the base and NVIDIA images at **42, 43, 44**:
   - Base 42/43 via `build.yml` → Run workflow → `source_tag=42` (then `43`). 44 is the
     normal `main` build (now also tagged `:44`).
   - NVIDIA 42/43/44 via `build-nvidia.yml` → Run workflow → `fedora_version=42` (then
     `43`, `44`). Needs the matching base tag to exist first.
   - The 42/43 builds may need per-version fixups (e.g. an F42-only package rename) —
     `check-build` will surface them, same as base bumps do.
2. Rebase, verifying GPU + sway after each reboot:
```bash
sudo ostree admin pin 0   # F41 is already pinned per rpm-ostree status; confirm

# 41 -> 42: UNVERIFIED, because the running ublue F41 deployment has ublue's policy,
# not ours, and ostree-image-signed reads the policy from the *running* deployment.
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/fbunt/sericea-main-nvidia:42
systemctl reboot

# now booted on an image carrying our policy.json (default reject) + cosign key, so
# switch to the signed transport for the rest (matches the laptop's journey).
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main-nvidia:43
systemctl reboot
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main-nvidia:44
systemctl reboot

sudo ostree admin pin 0   # pin the good F44; unpin F41 later once confident
```
Signing chain is already fixed in this repo (cosign v2 legacy attachments, key matches
`SIGNING_SECRET`). The `nvidia-580xx` branch must also exist in RPMfusion for F42/F43
(it does for F44; confirm when building those).

## Open questions / risks

1. ~~Pascal longevity~~ **Resolved:** mainline already dropped Pascal; we use the
   `nvidia-580xx` legacy branch. 580 is a legacy branch (~3 yr support window); if it is
   ever dropped, the next fallback is `nvidia-470xx` (Kepler) — but that's older than
   Pascal, so realistically 580xx is the floor for the 1070. `check-build` will surface a
   future break.
2. ~~akmod-at-build-time~~ **Resolved:** see the akmod-in-container gotcha above.
3. **sway + NVIDIA (open):** confirm `--unsupported-gpu` / `WLR_*` needed for the 1070 on
   Wayland — do this in Part A.5 on the real GPU.

## Repo state at time of writing

- `main` = Fedora 44; `ci-improvements` is **merged** (rechunk + build-required gate +
  lint + ISO workflows are live), plus the mesa-freeworld swap was dropped (it broke the
  F44 depsolve; do **not** reintroduce `mesa-*-freeworld` — see CLAUDE.md Key Constraints).
- Branch **`nvidia-variant`** (unpushed): `ci: version-tag the base image …` +
  `feat: add NVIDIA variant (proprietary 580xx akmod …)`. Open a PR / merge to trigger the
  base `:44` build, then run `build-nvidia.yml` for the stepping stones.
