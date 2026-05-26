# sericea-main

A signed Fedora atomic OCI image: a recreation of the discontinued [ublue `sway-atomic-main`][ublue-927] spin layered on top of Fedora's official [`sway-atomic`][quay-sway-atomic] base, plus an optional proprietary-NVIDIA variant for older (Pascal-era) GPUs. Consumed via the `ostree-image-signed` transport.

## Images

| Image | Tags | Contents |
|-------|------|----------|
| [`ghcr.io/fbunt/sericea-main`][pkg-base] | `:latest`, `:44`, `:YYYYMMDD` | Fedora `sway-atomic` + RPMfusion media stack (ffmpeg full codecs) + the [ublue `sway-atomic-main`][ublue-overlay] overlay + custom tools (Docker daemon stack, libvirt + virt-manager, neovim, gparted, …). |
| [`ghcr.io/fbunt/sericea-main-nvidia`][pkg-nvidia] | `:latest`, `:44`, `:YYYYMMDD` | The base image + `akmod-nvidia-580xx` (proprietary, compiled in-image), CUDA, and the libva-nvidia bridge. Pre-Turing GPUs aren't supported by NVIDIA's open kernel modules, so this image deliberately ships the proprietary kmod; the driver branch is a build arg so an `-open` variant for a Turing+ card is a one-line CI dispatch. |

Each image publishes `:latest` (current Fedora), a Fedora-major tag (e.g. `:44`) for version-pinned references, and a `:YYYYMMDD` snapshot per successful build.

## Rebasing to it

If you're already on a deployment that trusts this image's cosign key (e.g. a sericea-main deployment, or you've previously rebased to one), use the signed transport:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main:latest
systemctl reboot
```

If you're coming from a base whose `policy.json` doesn't trust this key yet (stock Fedora, ublue, etc.), the **first** rebase has to use the unverified transport — only after booting on an image that carries this repo's `policy.json` + `cosign.pub` can the signed transport verify it:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/fbunt/sericea-main:latest
systemctl reboot
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/fbunt/sericea-main:latest
systemctl reboot
```

Substitute `sericea-main-nvidia` for the NVIDIA variant — same pattern.

## Building locally

```bash
podman build -f Containerfile -t local-sericea-main .
```

Override the Fedora base tag (e.g. for a transient older-Fedora image):

```bash
podman build -f Containerfile --build-arg SOURCE_TAG=43 -t local-sericea-main .
```

The NVIDIA variant builds `FROM` the published base, so its tag must already exist:

```bash
podman build -f Containerfile.nvidia --build-arg SOURCE_TAG=latest -t local-sericea-main-nvidia .
```

## Signing

Each non-PR build signs with **cosign v2.4.1** — pinned because v3 writes OCI 1.1 referrer bundles that Fedora's `containers/image` stack can't read. Signing is by **tag reference**, not digest, so any pull of `:latest`/`:44`/timestamp resolves to a signed digest. `build.sh` bakes a `policy.json` (default `reject`, with `sigstoreSigned`/`matchRepository` rules scoped to both image repos) and a `registries.d` entry into every image, so a rebased system enforces the signature for future updates. The `SIGNING_SECRET` GitHub Actions secret holds the unencrypted cosign private key; only `cosign.pub` lives in this repo.

## CI

- **`build.yml`** — push, PR, daily schedule, and `workflow_dispatch`. Main builds publish `:latest`, `:44`, and `:YYYYMMDD`. The scheduled run is gated on Fedora's base image digest actually changing (tracked via the `dev.sericea.base-digest` label on the previous `:latest`), so identical days don't rebuild. The `source_tag` dispatch input builds a transient older-Fedora base (e.g. `42`/`43`) without moving `:latest`.
- **`build-nvidia.yml`** — schedule (30 min after the base) + `workflow_dispatch` only. No push trigger, because the NVIDIA layer's `FROM` needs the matching base tag to exist first. Inputs: `fedora_version` and `nvidia_driver` (default `nvidia-580xx`). Reuses the same cosign signing chain.
- **`lint.yml`** — `shellcheck` on the four shell scripts, `yamllint` on `.github/`.
- **`build-iso.yml`** — manual; produces an Anaconda installer ISO from the published image via `bootc-image-builder`.

## Notable constraints

Non-obvious gotchas worth knowing before changing the build. Full prose is in [`CLAUDE.md`](./CLAUDE.md).

- Don't swap mesa to RPMfusion's `mesa-*-freeworld` drivers — they exact-version-pin Fedora's `mesa-filesystem` and depsolve drift hard-fails the build. `build.sh` intentionally swaps only the ffmpeg stack.
- The NVIDIA variant must build the **proprietary** kmod. RPMfusion's 580xx kmod spec auto-detects the GPU to choose open vs proprietary, and on a headless CI runner that picks open — which doesn't support pre-Turing GPUs. `build-nvidia.sh` defines `_without_kmod_nvidia_detect` to skip the detection, and `check-build-nvidia.sh` asserts the built kmod's license so a wrong variant fails the build, not the boot.
- Every `RUN` layer in the `Containerfile`s must end with `ostree container commit`.
- Never commit `cosign.key` — only `cosign.pub` belongs in the repo.

## Origin & license

The package overlay is sourced from [`ublue-os/main@4d1a14d`][ublue-overlay] (the discontinued `sway-atomic-main` spin, deprecated in [ublue-os/main#927][ublue-927]). The base image is Fedora's official `sway-atomic` (`quay.io/fedora-ostree-desktops/sway-atomic`). Licensed under the [Apache License 2.0](./LICENSE).

[pkg-base]: https://github.com/fbunt/sericea-main/pkgs/container/sericea-main
[pkg-nvidia]: https://github.com/fbunt/sericea-main/pkgs/container/sericea-main-nvidia
[ublue-overlay]: https://github.com/ublue-os/main/blob/4d1a14d/packages.json
[ublue-927]: https://github.com/ublue-os/main/issues/927
[quay-sway-atomic]: https://quay.io/repository/fedora-ostree-desktops/sway-atomic
