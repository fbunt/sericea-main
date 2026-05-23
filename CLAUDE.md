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

- **`build.yml`** — builds with `buildah`, rechunks (`hhd-dev/rechunk`) for smaller upgrade deltas, pushes to `ghcr.io/<owner>/sericea-main`, and signs with `cosign` using `SIGNING_SECRET` (only on non-PR builds). A `check` job gates the build: non-`schedule` events always build, but the daily cron only rebuilds when Fedora's base digest differs from the `dev.sericea.base-digest` label recorded on the last `:latest` (base ref is read from the `Containerfile`). Rechunk strips labels, so labels — including `dev.sericea.base-digest` — are re-applied via its `labels` input.
- **`lint.yml`** — `shellcheck` on `build.sh`/`check-build.sh` and `yamllint` on `.github/` (config in `.yamllint`). Runs on push/PR.
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
- Do **not** swap mesa to RPMfusion's `mesa-*-freeworld` drivers. They exact-version-pin Fedora's `mesa-filesystem`, so any drift between the base image's mesa and RPMfusion's freeworld build (frequent) hard-fails the depsolve and breaks the build. Fedora's stock `mesa-va-drivers`/`mesa-vulkan-drivers` ship the hardware video codecs since F40, so the swap is unnecessary; `build.sh` intentionally swaps only the ffmpeg stack. (ublue-os/main dropped freeworld mesa for the same reason, sourcing the full mesa stack from a single repo instead.)
- Never commit `cosign.key` — only `cosign.pub` belongs in the repo.
- The `SIGNING_SECRET` GitHub Actions secret must hold the unencrypted `cosign.key` contents.
