# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a custom OCI image based on Fedora's `sway-atomic` image (`quay.io/fedora-ostree-desktops/sway-atomic`). The `build.sh` overlay recreates the package set of the discontinued `ghcr.io/ublue-os/sway-atomic-main` spin (deprecated in ublue-os/main#927), then layers additional custom packages on top. The image is built via GitHub Actions and published to GHCR.

## Architecture

There are only two files that define the image:

- **`Containerfile`** — Declares build args (`SOURCE_REGISTRY`, `SOURCE_IMAGE`, `SOURCE_TAG`) and the `FROM` line, then copies and runs `build.sh`. Every `RUN` block must end with `ostree container commit`.
- **`build.sh`** — The customization script. Enables RPMfusion, installs the ublue-style overlay packages, installs the project-specific extras, wires up cosign signature verification, and adds the Flathub Flatpak remote.

The Containerfile also copies `cosign.pub` to `/etc/pki/containers/sericea-main.pub`; `build.sh` writes a `registries.d` entry and a scoped `sigstoreSigned` rule into `policy.json` so the image can be rebased with the verified `ostree-image-signed` transport.

The CI workflow (`.github/workflows/build.yml`) builds with `buildah`, pushes to `ghcr.io/<owner>/sericea-main`, and signs the image with `cosign` using `SIGNING_SECRET` (only on non-PR builds).

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
- Never commit `cosign.key` — only `cosign.pub` belongs in the repo.
- The `SIGNING_SECRET` GitHub Actions secret must hold the unencrypted `cosign.key` contents.
