# NVIDIA variant — plan & migration

Status: **planned, not yet implemented.** This captures the design so the work can
continue on the workstation (which has the actual GPU and is the migration target).

## Why

A second machine (the workstation) is still on the **retired ublue-os
`sericea-nvidia` spin at Fedora 41** — the same dead-base situation the laptop was in
when this project started. It needs to move onto this repo's image, with NVIDIA
support, eventually at Fedora 44.

The laptop has already completed the journey (ublue F42 → this repo's image → F43 → F44,
on the signed `ostree-image-signed` transport). The workstation is one major further
back **and** needs the NVIDIA driver, which this repo does not yet build.

## Decisions (locked)

- **GPU:** GTX 1070 = **Pascal** → must use the **proprietary `akmod-nvidia`** (the
  open kernel modules require Turing or newer; they do *not* support Pascal).
- **CUDA:** included (`xorg-x11-drv-nvidia-cuda`). Pascal (sm_61) is fine with the
  current driver/CUDA libs.
- **Delivery:** a **separate image**, `ghcr.io/fbunt/sericea-main-nvidia`, not a tag on
  the base image.
- **Future-proofing:** the driver is a **build arg** so an `-open` variant (for a future
  Turing+/Blackwell GPU) is a one-line CI matrix addition later. We do *not* build
  `-open` now — proprietary covers Pascal→Ada, which spans any realistic next card.

Note: a single image cannot contain both `akmod-nvidia` and `akmod-nvidia-open` — they
provide the same `nvidia.ko` and conflict, and the module is baked at build time.
"Supporting both" therefore means two parameterized images, not one.

## Part A — build the NVIDIA variant (do this first, on the workstation)

Build NVIDIA as a layer on top of the existing base image so it inherits the entire
sway / RPMfusion / signing / `check-build.sh` setup and only adds GPU bits.

- **`Containerfile.nvidia`** — `FROM ghcr.io/fbunt/sericea-main:<tag>` (the base we
  already build), with a build arg for the driver:
  ```dockerfile
  ARG SOURCE_REGISTRY="ghcr.io/fbunt"
  ARG SOURCE_IMAGE="sericea-main"
  ARG SOURCE_TAG="44"
  ARG NVIDIA_DRIVER="nvidia"   # "nvidia" (proprietary) | "nvidia-open" (Turing+)
  FROM ${SOURCE_REGISTRY}/${SOURCE_IMAGE}:${SOURCE_TAG}
  COPY build-nvidia.sh /tmp/build-nvidia.sh
  RUN /tmp/build-nvidia.sh && ostree container commit
  ```

- **`build-nvidia.sh`** — installs and compiles the module at image-build time so
  nothing builds at runtime (atomic image). Sketch:
  - RPMfusion is already enabled in the base image, so the akmod packages resolve.
  - Install `akmod-${NVIDIA_DRIVER}` + `xorg-x11-drv-nvidia-cuda` + `nvidia-vaapi-driver`
    + `kernel-devel` matching the **base image's kernel**:
    `rpm-ostree install kernel-devel-$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel) ...`
  - Build the kmod for that exact kernel:
    `akmods --force --kernels "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)"`
    (Confirm the akmods invocation/module name during the first local build — this is
    the finicky part. Reference: Fedora bootc + NVIDIA examples; ublue did this in a
    separate `akmods` image, but building in-layer works on a Fedora base.)
  - Drop nouveau blacklist + modeset:
    - `/usr/lib/modprobe.d/blacklist-nouveau.conf` → `blacklist nouveau`
    - `/usr/lib/bootc/kargs.d/00-nvidia.toml` →
      `kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]`
  - **sway-on-NVIDIA tweak:** wlroots needs `--unsupported-gpu` and usually
    `WLR_NO_HARDWARE_CURSORS=1` / `WLR_RENDERER=vulkan` env. Add a drop-in (e.g. an env
    file or a `/usr/share/sway` config snippet) — verify on the actual GPU.
  - Run a check at the end (extend `check-build.sh` or a parallel `check-build-nvidia.sh`)
    asserting the module is present:
    `find /usr/lib/modules -name 'nvidia.ko*'` and `rpm -q akmod-${NVIDIA_DRIVER}`.

- **CI:** add a job that builds `sericea-main-nvidia` **after** the base image
  publishes, `FROM` the just-pushed base, reusing the **same rechunk + cosign signing +
  build-required** machinery. Easiest as a second matrix entry or a dependent job in
  `build.yml`; publish to the `sericea-main-nvidia` package with the same tag scheme.
  The cosign key/policy are identical (same repo owner) — the existing `policy.json`
  scope should be widened to cover `ghcr.io/fbunt/sericea-main-nvidia` too.

## Part B — workstation migration (stepping stones)

The first move is a **cross-base rebase** (off ublue) spanning 41→44 = three majors. A
rebase is a full atomic image swap (rollback-able), so the NVIDIA driver isn't the
cross-version risk — each target image is internally consistent. The risk is `/etc` +
`/var` config drift across three Fedora versions, so step one major at a time and verify
boot + GPU at each stop.

Build the NVIDIA variant at **42, 43, 44** (the 42/43 images are transient, only for the
hops), then:

```bash
# on the workstation, pin the current known-good F41 deployment first:
sudo ostree admin pin 0

# 1 major at a time, verify GPU + sway after each reboot:
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/fbunt/sericea-main-nvidia:42   # 41 -> 42
systemctl reboot
# (then switch to the signed transport once on an image that carries the policy+key,
#  same as the laptop did — see below)
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main-nvidia:43
systemctl reboot
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main-nvidia:44
systemctl reboot
```

Signing/transport caveat (learned on the laptop): `ostree-image-signed` reads the policy
from the *currently running* deployment and refuses a policy whose default is
`insecureAcceptAnything`. The ublue F41 base will not have this repo's policy, so the
**first hop uses `ostree-unverified-registry`**; once booted on an image that carries the
corrected `policy.json` (default `reject`) + the cosign pub key, switch to
`ostree-image-signed` for the rest. The signing chain itself is already fixed in this
repo (cosign v2 legacy attachments, rotated key matching `SIGNING_SECRET`).

## Open questions / risks to resolve during implementation

1. **Pascal longevity:** confirm the current RPMfusion `akmod-nvidia` branch still
   supports Pascal (it does today; NVIDIA is moving older gens toward legacy). If a
   future bump drops it, fall back to the legacy akmod (`nvidia-470xx`-style) — the
   build/`check-build` will surface this.
2. **akmod-at-build-time:** the exact `akmods` invocation and `kernel-devel` matching is
   the main thing to nail on the first local build (on the workstation).
3. **sway + NVIDIA:** confirm the `--unsupported-gpu` / `WLR_*` settings needed for the
   1070 on Wayland.

## Repo state at time of writing

- `main` = Fedora 44, working cosign signing, `check-build.sh` + `bootc container lint`.
- Branch **`ci-improvements`** (open, pushed) adds: lint workflow, build-required gate,
  rechunk, and a manual installer-ISO workflow — open a PR to `main` to validate the
  rechunk build, then merge. The NVIDIA work should build on top of that (it reuses the
  rechunk/sign/gate machinery).
