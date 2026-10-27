# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a custom OCI image based on Fedora's `sway-atomic` image (`quay.io/fedora-ostree-desktops/sway-atomic`). The `build.sh` overlay recreates the package set of the discontinued `ghcr.io/ublue-os/sway-atomic-main` spin (deprecated in ublue-os/main#927), then layers additional custom packages on top. The image is built via GitHub Actions and published to GHCR.

## Architecture

Three files define the image:

- **`Containerfile`** — Declares build args (`SOURCE_REGISTRY`, `SOURCE_IMAGE`, `SOURCE_TAG`) and the `FROM` line, then copies and runs `build.sh`. Every `RUN` block must end with `ostree container commit`.
- **`build.sh`** — The customization script. Enables RPMfusion, installs the ublue-style overlay packages, installs the project-specific extras, wires up cosign signature verification, adds the Flathub Flatpak remote, and finally runs `check-build.sh`.
- **`check-build.sh`** — Build-time smoke test (modeled on ublue-os/main). Asserts critical packages are present (`rpm -q`), `policy.json` is valid with a `reject` default, and `bootc container lint` passes. Runs at the end of `build.sh` so a broken image fails the build before it is pushed or signed — this is what catches Fedora package renames across major-version bumps.

The Containerfile also copies `cosign.pub` to `/etc/pki/containers/sericea-main.pub`; `build.sh` writes a `registries.d` entry and a scoped `sigstoreSigned` rule into `policy.json` so the image can be rebased with the verified `ostree-image-signed` transport.

## CI workflows

- **`build.yml`** — builds with `buildah`, pushes to `ghcr.io/<owner>/sericea-main`, and signs with `cosign` using `SIGNING_SECRET` (only on non-PR builds). Main builds also publish the Fedora-major tag (e.g. `:44`) alongside `:latest`/timestamp so version-pinned refs resolve; a `workflow_dispatch` `source_tag` input builds a transient older-Fedora base (42/43) without moving `:latest`. A `check` job gates the build: non-`schedule` events always build, but the daily cron only rebuilds when Fedora's base digest differs from the `dev.sericea.base-digest` label recorded on the last `:latest` (base ref is read from the `Containerfile`). (Rechunk was dropped: `hhd-dev/rechunk` runs `sudo podman create` against root storage but `buildah-build` writes rootless, so it never succeeded; images push un-rechunked = larger upgrade deltas.)
- **`build-nvidia.yml`** — builds the NVIDIA variant `sericea-main-nvidia` as a layer `FROM` the published `sericea-main:<version>` (so it needs the base tag to exist first), reusing the cosign signing. Runs on the daily schedule (after `build.yml`) and `workflow_dispatch` only — no push trigger, since it can't run before the base publishes. `fedora_version`/`nvidia_driver` inputs build the stepping stones (42/43/44) and select the akmod branch (default `nvidia-580xx`, required for the Pascal GTX 1070).
- **`lint.yml`** — `shellcheck` on `build.sh`/`check-build.sh`/`build-nvidia.sh`/`check-build-nvidia.sh` and `yamllint` on `.github/` (config in `.yamllint`). Runs on push/PR.
- **`build-iso.yml`** — manual (`workflow_dispatch`); builds an Anaconda installer ISO from the published image via `bootc-image-builder` and uploads it as a workflow artifact. ISO user config lives in `iso/config.toml` (replace the placeholder credential before relying on it).

## Local Build

```bash
podman build -f Containerfile -t local-sericea-main .
```

Override the source with build args:

```bash
podman build -f Containerfile \
  --build-arg SOURCE_REGISTRY=quay.io/fedora-ostree-desktops \
  --build-arg SOURCE_IMAGE=sway-atomic \
  --build-arg SOURCE_TAG=44 \
  -t local-sericea-main .
```

## Key Constraints

- Every `RUN` layer in the `Containerfile` must end with `ostree container commit` (rpm-ostree container requirement).
- `/var/lib/alternatives` must be created before running `build.sh` to prevent RPM install failures.
- RPMfusion (free + nonfree) is enabled in `build.sh`, so package additions can rely on it.
- RPMfusion's `mesa-va-drivers-freeworld` (H.264/HEVC VA-API; Fedora's mesa VA drivers, now in `mesa-dri-drivers`, lack them: F44 radeonsi `vainfo` shows only JPEG/VP9/AV1) is installed **best-effort only**. It exact-pins `mesa-filesystem` to its own version and RPMfusion's build often lags or leads the base image's mesa, so `build.sh` requests only `mesa-va-drivers-freeworld-<installed mesa-filesystem VERSION>` and warns instead of failing when that is missing or won't depsolve; `check-build.sh` only reports it. Never make it a hard requirement, never let it upgrade/downgrade the base mesa, and don't add `mesa-vulkan-drivers-freeworld` (it conflicts with `mesa-vulkan-drivers`). No env var is needed: Fedora's libva searches `/usr/lib64/dri-freeworld` before `/usr/lib64/dri`.
- The NVIDIA variant ships the **proprietary** kmod. RPMfusion's 580xx kmod spec does runtime GPU detection to choose open vs proprietary; on a headless CI runner that picks **open**, which silently breaks pre-Turing GPUs (the GTX 1070 / Pascal target — fails at the user's boot, not the build). `build-nvidia.sh` writes `%_without_kmod_nvidia_detect 1` to `/etc/rpm/macros.*` before `akmodsbuild` to skip the detection (the default kernel tree is proprietary); `check-build-nvidia.sh` asserts the built kmod's license matches the requested branch (`NVIDIA` = proprietary, `Dual MIT/GPL` = open) so the wrong variant fails the build, not the boot. Don't drop either without switching `NVIDIA_DRIVER` to an `-open` variant.
- Keep `build.sh`'s nouveau-omitting dracut run after every package install, and keep the initramfs under the 160M ceiling `check-build.sh` enforces: each deployment's kernel + initramfs must fit three-plus times in a 1G `/boot` (rationale in the `build.sh` comment).
- Never commit `cosign.key` — only `cosign.pub` belongs in the repo.
- The `SIGNING_SECRET` GitHub Actions secret must hold the unencrypted `cosign.key` contents.
