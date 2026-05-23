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
# moby-engine + docker-buildx already arrive as weak deps of the docker stack,
# but list them explicitly so they're requested packages (won't vanish if a weak
# dep is ever dropped). podman-compose is the only genuinely missing one.
rpm-ostree install \
    containerd \
    docker-buildx \
    docker-cli \
    docker-compose \
    docker-compose-switch \
    gparted \
    keychain \
    libvirt \
    mediawriter \
    moby-engine \
    neovim \
    podman-compose \
    powertop \
    tio \
    qemu-img \
    qemu-kvm \
    virt-manager


### Libvirt + Docker coexistence (VM internet)
# moby-engine sets the iptables FORWARD policy to DROP and only accepts traffic
# via its own chains, which excludes libvirt's virbr0 NAT — so virt-manager VMs
# can reach the host but not the internet. Docker promises never to touch the
# DOCKER-USER chain, so add virbr0 accept rules there via a oneshot that runs
# after docker.service. See docs/libvirt-vm-no-internet-fix.md.
cat > /usr/lib/systemd/system/libvirt-docker-forward.service <<'EOF'
[Unit]
Description=Allow libvirt VMs through the Docker FORWARD chain
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables -I DOCKER-USER -i virbr0 -j ACCEPT
ExecStart=/usr/sbin/iptables -I DOCKER-USER -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
# Enable via a /usr wants symlink (image-managed; no dependence on /etc merge).
mkdir -p /usr/lib/systemd/system/multi-user.target.wants
ln -sf ../libvirt-docker-forward.service \
    /usr/lib/systemd/system/multi-user.target.wants/libvirt-docker-forward.service


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
