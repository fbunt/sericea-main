#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"


### Enable RPMfusion (required for ffmpeg/codec packages below)
rpm-ostree install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${RELEASE}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${RELEASE}.noarch.rpm"


### Swap Fedora's patent-stripped ffmpeg stack for RPMfusion's full versions
# Fedora ships "-free" ffmpeg packages that omit patent-encumbered codecs
# (H.264/HEVC encode, AAC, AC-3, MP3 encode, etc). Replace them with RPMfusion's
# full ffmpeg. The exact set shifts every Fedora release (F43 renamed
# mesa-libxatracker; F44 dropped libpostproc-free), so discover whatever stripped
# ffmpeg packages are actually installed, remove those, and pull in the full
# RPMfusion versions. Dynamic so future bumps don't break.
#
# NOTE: deliberately NOT swapping mesa to RPMfusion's mesa-*-freeworld drivers.
# Those addon subpackages exact-version-pin Fedora's mesa-filesystem, so whenever
# the base image's mesa drifts from RPMfusion's freeworld build (frequent: mesa
# moves fast, RPMfusion lags then leaps past it) the depsolve hard-fails the whole
# build. Fedora's stock mesa-va-drivers/mesa-vulkan-drivers have shipped the hw
# video codecs since F40, so the freeworld swap buys little; ublue-os/main dropped
# it for the same reason. See CLAUDE.md "Key Constraints".
mapfile -t STRIPPED < <(rpm -qa --queryformat '%{NAME}\n' \
    | grep -E '^(ffmpeg-free|libav[a-z]+-free|libsw[a-z]+-free|libpostproc-free)$' || true)
rpm-ostree override remove "${STRIPPED[@]}" \
    --install=ffmpeg \
    --install=ffmpeg-libs \
    --install=libavcodec-freeworld


### Additive RPMfusion codec packages
# These coexist alongside their Fedora -free counterparts and add patent-
# encumbered codec support (AAC encode, HEIF/HEVC decode, MP3, etc).
rpm-ostree install \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    libheif-freeworld


### ublue sway-atomic-main overlay
# Recreates the package set the discontinued ghcr.io/ublue-os/sway-atomic-main
# layered on top of Fedora's sway-atomic image. Source: ublue-os/main@4d1a14d
# packages.json — "all"."all" + "all"."sway-atomic".
rpm-ostree install \
    alsa-firmware \
    apr \
    apr-util \
    clipman \
    distrobox \
    fdk-aac \
    ffmpegthumbnailer \
    flatpak-spawn \
    fuse \
    fzf \
    grub2-tools-extra \
    google-noto-sans-balinese-fonts \
    google-noto-sans-cjk-fonts \
    google-noto-sans-javanese-fonts \
    google-noto-sans-sundanese-fonts \
    gvfs-mtp \
    heif-pixbuf-loader \
    htop \
    intel-vaapi-driver \
    just \
    libcamera \
    libcamera-tools \
    libcamera-gstreamer \
    libcamera-ipa \
    libheif \
    libratbag-ratbagd \
    libva-utils \
    lshw \
    mesa-compat-libxatracker \
    net-tools \
    nvme-cli \
    nvtop \
    openrgb-udev-rules \
    openssl \
    pam-u2f \
    pam_yubico \
    pamu2fcfg \
    pipewire-plugin-libcamera \
    powerstat \
    smartmontools \
    solaar-udev \
    squashfs-tools \
    symlinks \
    tcpdump \
    thunar-volman \
    tmux \
    traceroute \
    tumbler \
    vim \
    wireguard-tools \
    wl-clipboard \
    xhost \
    xorg-x11-xauth \
    yubikey-manager \
    zstd


### Custom packages
rpm-ostree install \
    containerd \
    docker-cli \
    docker-compose \
    docker-compose-switch \
    gparted \
    keychain \
    libvirt \
    mediawriter \
    neovim \
    powertop \
    tio \
    qemu-img \
    qemu-kvm \
    virt-manager


### Default wallpaper — swaybg can't decode F44's JXL default
# F44 ships only JXL desktop wallpapers, and the gdk-pixbuf JXL loader the stock
# sway config asks for (jxl-pixbuf-loader, see /etc/sway/config) has been dropped
# from Fedora's repos — so swaybg renders no wallpaper out of the box. Decode the
# resolved default to PNG (ffmpeg, installed above, has a libjxl decoder; PNG is
# built into gdk-pixbuf) and point sway at it via a config.d drop-in, which the
# stock config includes after its own bg line, so this one wins. Guarded on the
# JXL symlink so it no-ops on releases that already ship a raster default.
if [ -e /usr/share/backgrounds/default.jxl ]; then
    ffmpeg -hide_banner -loglevel error -y \
        -i "$(readlink -f /usr/share/backgrounds/default.jxl)" \
        /usr/share/backgrounds/default.png
    mkdir -p /usr/share/sway/config.d
    cat > /usr/share/sway/config.d/10-sericea-wallpaper.conf <<'EOF'
# Stock sway config points at default.jxl, which swaybg cannot decode (Fedora has
# no JXL gdk-pixbuf loader). Use the PNG decoded from it at build time instead.
output * bg /usr/share/backgrounds/default.png fill
EOF
fi


### Container signature verification
# Trust this image's cosign signature (key copied in by the Containerfile) so
# it can be pulled/rebased with the verified ostree-image-signed transport.
IMAGE_REPO="ghcr.io/fbunt/sericea-main"

# Tell containers/image the signatures live as sigstore attachments on the repo.
cat > /etc/containers/registries.d/sericea-main.yaml <<EOF
docker:
  ${IMAGE_REPO}:
    use-sigstore-attachments: true
EOF

# Require a valid cosign signature for this repo. The ostree-image-signed
# transport refuses to run when the policy default is a lone
# `insecureAcceptAnything` (ostree-rs-ext container_policy_is_default_insecure),
# so the default must be `reject`; per-transport "" catch-alls keep every other
# image pull working exactly as before.
cat > /etc/containers/policy.json <<EOF
{
    "default": [{"type": "reject"}],
    "transports": {
        "docker": {
            "${IMAGE_REPO}": [
                {
                    "type": "sigstoreSigned",
                    "keyPath": "/etc/pki/containers/sericea-main.pub",
                    "signedIdentity": {"type": "matchRepository"}
                }
            ],
            "": [{"type": "insecureAcceptAnything"}]
        },
        "docker-daemon": {"": [{"type": "insecureAcceptAnything"}]},
        "containers-storage": {"": [{"type": "insecureAcceptAnything"}]},
        "dir": {"": [{"type": "insecureAcceptAnything"}]},
        "oci": {"": [{"type": "insecureAcceptAnything"}]},
        "oci-archive": {"": [{"type": "insecureAcceptAnything"}]},
        "docker-archive": {"": [{"type": "insecureAcceptAnything"}]},
        "tarball": {"": [{"type": "insecureAcceptAnything"}]}
    }
}
EOF

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo


### Build-time smoke test (fails the build if the image is broken)
/tmp/check-build.sh
