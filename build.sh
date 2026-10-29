#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %fedora)"


### Enable RPMfusion (required for ffmpeg/codec packages below)
# mirrors.rpmfusion.org is a MirrorBrain redirector whose GeoDNS chain
# occasionally fails to resolve from CI runners. Retry only on DNS-failure
# signatures so depsolve/signing breaks still fail fast instead of being
# masked by the loop.
for i in 1 2 3; do
    rpm-ostree install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${RELEASE}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${RELEASE}.noarch.rpm" \
        2> >(tee /tmp/rpmfusion.err >&2) && break
    grep -qE "dns error|Name or service not known" /tmp/rpmfusion.err || exit 1
    [ "$i" -eq 3 ] && exit 1
    sleep $((i * 10))
done


### Swap Fedora's patent-stripped ffmpeg stack for RPMfusion's full versions
# Fedora ships "-free" ffmpeg packages that omit patent-encumbered codecs
# (H.264/HEVC encode, AAC, AC-3, MP3 encode, etc). Replace them with RPMfusion's
# full ffmpeg. The exact set shifts every Fedora release (F43 renamed
# mesa-libxatracker; F44 dropped libpostproc-free), so discover whatever stripped
# ffmpeg packages are actually installed, remove those, and pull in the full
# RPMfusion versions. Dynamic so future bumps don't break.
#
# NOTE: mesa is not swapped here. Its VA-API drivers get a best-effort freeworld
# add-on below, which must never fail the build.
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


### Best-effort H.264/HEVC VA-API drivers (RPMfusion mesa-va-drivers-freeworld)
# Fedora builds mesa's VA-API drivers (now shipped in mesa-dri-drivers) without
# the patent-encumbered codecs: on F44 radeonsi, vainfo lists JPEG, VP9 and AV1
# but no H.264/HEVC. The freeworld build adds them under /usr/lib64/dri-freeworld,
# which Fedora's libva searches before /usr/lib64/dri (its compiled-in path is
# dri-nonfree:dri-freeworld:dri), so it wins with no env var. It also puts its
# full libgallium build on the ld.so path (GL loads it too) and exact-pins
# mesa-filesystem to its version. RPMfusion's build often lags or leads Fedora's
# mesa, so request only the build matching the installed mesa version;
# rpm-ostree never moves base packages, so a missing build or failed depsolve
# just warns and the image ships without it. mesa-vulkan-drivers-freeworld is
# left out: it conflicts with mesa-vulkan-drivers and VA-API is what video
# playback uses.
if ! MESA_VERSION="$(rpm -q --queryformat '%{VERSION}\n' mesa-filesystem | head -n1)" ||
    ! rpm-ostree install "mesa-va-drivers-freeworld-${MESA_VERSION}"; then
    echo "WARNING: installing mesa-va-drivers-freeworld matching mesa-filesystem '${MESA_VERSION}' failed (no matching RPMfusion build, depsolve or mirror error); image ships without H.264/HEVC VA-API"
fi


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
# fuse-libs ships /usr/lib64/libfuse.so.2 which AppImage runtimes dlopen to
# mount their squashfs payload; without it AppImages fail at launch.
rpm-ostree install \
    containerd \
    docker-buildx \
    docker-cli \
    docker-compose \
    docker-compose-switch \
    fuse-libs \
    gparted \
    keychain \
    libvirt \
    mediawriter \
    moby-engine \
    ncdu \
    neovim \
    podman-compose \
    powertop \
    tio \
    qemu-img \
    qemu-kvm \
    virt-manager


### Tailscale (remote access over the tailnet)
# Not packaged by Fedora or RPMfusion; install from Tailscale's stable repo.
curl -fsSLo /etc/yum.repos.d/tailscale.repo \
    https://pkgs.tailscale.com/stable/fedora/tailscale.repo
rpm-ostree install tailscale
# Enable via a /usr wants symlink (image-managed; no dependence on /etc merge).
mkdir -p /usr/lib/systemd/system/multi-user.target.wants
ln -sf ../tailscaled.service \
    /usr/lib/systemd/system/multi-user.target.wants/tailscaled.service


### Keep firmware update metadata current
# Fedora doesn't enable fwupd-refresh.timer, so without it fwupdmgr never
# downloads LVFS metadata and reports no BIOS/EC updates even when Lenovo has
# published some.
mkdir -p /usr/lib/systemd/system/timers.target.wants
ln -sf ../fwupd-refresh.timer \
    /usr/lib/systemd/system/timers.target.wants/fwupd-refresh.timer


### Libvirt + Docker coexistence (VM internet)
# When dockerd turns on IP forwarding it sets the iptables FORWARD policy to DROP
# and only accepts traffic via its own chains, which excludes libvirt's virbr0
# NAT — so virt-manager VMs can reach the host but not the internet. dockerd
# never alters rules in the DOCKER-USER chain, so add virbr0 accept rules there
# via a oneshot hooked onto docker.service. It is wanted by docker.service, not
# multi-user.target, and must not Want= it back: dockerd starts on demand from
# docker.socket (Fedora's preset) instead of idling from boot. PartOf= re-runs
# it on a docker restart; the rules outlive dockerd restarts, so each is checked
# (-C) before it is inserted. See docs/libvirt-vm-no-internet-fix.md.
cat > /usr/lib/systemd/system/libvirt-docker-forward.service <<'EOF'
[Unit]
Description=Allow libvirt VMs through the Docker FORWARD chain
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/sbin/iptables -C DOCKER-USER -i virbr0 -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I DOCKER-USER -i virbr0 -j ACCEPT'
ExecStart=/bin/sh -c '/usr/sbin/iptables -C DOCKER-USER -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I DOCKER-USER -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT'
RemainAfterExit=yes

[Install]
WantedBy=docker.service
EOF
# Enable via a /usr wants symlink (image-managed; no dependence on /etc merge).
mkdir -p /usr/lib/systemd/system/docker.service.wants
ln -sf ../libvirt-docker-forward.service \
    /usr/lib/systemd/system/docker.service.wants/libvirt-docker-forward.service


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


### Rebuild CA trust bundles at boot
# update-ca-trust writes its extracted bundles (the PEM/OpenSSL/Java files most
# non-NSS clients read) under /etc. A local trust change (an anchor or blocklist
# entry plus update-ca-trust) turns them into local modifications that ostree's
# /etc merge carries forward on every upgrade, so later ca-certificates updates
# in the image (root removals included) would never reach them. Regenerate them
# from the current sources early in each boot.
cat > /usr/lib/systemd/system/ca-trust-extract.service <<'EOF'
[Unit]
Description=Rebuild CA trust bundles from current sources
DefaultDependencies=no
RequiresMountsFor=/etc/pki/ca-trust/extracted
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/bin/update-ca-trust extract
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
# Enable via a /usr wants symlink (image-managed; no dependence on /etc merge).
mkdir -p /usr/lib/systemd/system/sysinit.target.wants
ln -sf ../ca-trust-extract.service \
    /usr/lib/systemd/system/sysinit.target.wants/ca-trust-extract.service


### Distrust emSign ECC Root CA - G3 (eMudhra intermediate key compromise)
# Eight eMudhra intermediates under this root were issued with private keys
# small enough to brute-force, so anyone can mint certificates that chain to it.
# Browsers block them on their own; this covers everything that reads the system
# store until Fedora's ca-certificates drops the root (FEDORA-2026-56e14eb520).
# The entry lives under /usr so it stays image-owned. SHA-256:
# 86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B
# Remove this block once the build logs the notice below.
anchors="$(trust list --filter=ca-anchors)"
if ! grep -q 'label: emSign ECC Root CA - G3' <<<"$anchors"; then
    echo "NOTICE: Fedora no longer ships emSign ECC Root CA - G3; its blocklist entry can be removed"
fi
cat > /usr/share/pki/ca-trust-source/blocklist/emsign-ecc-g3.pem <<'EOF'
-----BEGIN CERTIFICATE-----
MIICTjCCAdOgAwIBAgIKPPYHqWhwDtqLhDAKBggqhkjOPQQDAzBrMQswCQYDVQQG
EwJJTjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNo
bm9sb2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0g
RzMwHhcNMTgwMjE4MTgzMDAwWhcNNDMwMjE4MTgzMDAwWjBrMQswCQYDVQQGEwJJ
TjETMBEGA1UECxMKZW1TaWduIFBLSTElMCMGA1UEChMcZU11ZGhyYSBUZWNobm9s
b2dpZXMgTGltaXRlZDEgMB4GA1UEAxMXZW1TaWduIEVDQyBSb290IENBIC0gRzMw
djAQBgcqhkjOPQIBBgUrgQQAIgNiAAQjpQy4LRL1KPOxst3iAhKAnjlfSU2fySU0
WXTsuwYc58Byr+iuL+FBVIcUqEqy6HyC5ltqtdyzdc6LBtCGI79G1Y4PPwT01xyS
fvalY8L1X44uT6EYGQIrMgqCZH0Wk9GjQjBAMB0GA1UdDgQWBBR8XQKEE9TMipuB
zhccLikenEhjQjAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAKBggq
hkjOPQQDAwNpADBmAjEAvvNhzwIQHWSVB7gYboiFBS+DCBeQyh+KTOgNG3qxrdWB
CUfvO6wIBHxcmbHtRwfSAjEAnbpV/KlK6O3t5nYBQnvI+GDZjVGLVTv7jHvrZQnD
+JbNR6iC8hZVdyR+EhCVBCyj
-----END CERTIFICATE-----
EOF
update-ca-trust extract


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


### Suspend-then-hibernate (opt-in per machine; see docs/hibernation.md)
# s2idle drains a closed laptop in a few days, so a closed lid suspends and then
# hibernates after 30 minutes. Hibernation needs a disk swap file, which is
# per-machine state in /var: enable-hibernation creates it. Everything here is
# inert until then. logind falls back to plain suspend when suspend-then-hibernate is not
# possible (no swap file), and machines without a lid never see a lid event.
# Lid closed with an external display or dock: ignore (logind's default), so
# clamshell use with a monitor keeps working.
mkdir -p /usr/lib/systemd/logind.conf.d /usr/lib/systemd/sleep.conf.d
cat > /usr/lib/systemd/logind.conf.d/60-lid-suspend-then-hibernate.conf <<'EOF'
# Closed lid: suspend, then hibernate after HibernateDelaySec (sleep.conf.d).
# Without a usable swap file logind falls back to plain suspend.
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
HandleLidSwitchDocked=ignore
EOF
# HibernateOnACPower keeps its default (yes): it hibernates after 30min on AC too.
cat > /usr/lib/systemd/sleep.conf.d/60-hibernate-delay.conf <<'EOF'
[Sleep]
HibernateDelaySec=30min
EOF
# The swap file's unit. ConditionPathExists keeps it a no-op until
# enable-hibernation creates the file. Priority 10 sits below zram0 (100), so
# zram still takes normal swapping and the disk file is overflow plus the
# hibernation target.
cat > /usr/lib/systemd/system/var-swap-swapfile.swap <<'EOF'
[Unit]
Description=Disk swap file for hibernation and zram overflow
Documentation=man:systemd.swap(5)
ConditionPathExists=/var/swap/swapfile

[Swap]
What=/var/swap/swapfile
Priority=10

[Install]
WantedBy=swap.target
EOF
# Enable via a /usr wants symlink (image-managed; no dependence on /etc merge).
mkdir -p /usr/lib/systemd/system/swap.target.wants
ln -sf ../var-swap-swapfile.swap \
    /usr/lib/systemd/system/swap.target.wants/var-swap-swapfile.swap
# logind (CanHibernate) and systemd-sleep may only read a swap file labelled
# swapfile_t; under the default var_t they are denied and report hibernation
# as unavailable. The rule is set here, not by semanage on the host, because a
# runtime semanage rewrites /etc/selinux/targeted, which then stops following
# image updates. It prints a harmless "Invalid cross-device link" warning.
semanage fcontext -a -t swapfile_t '/var/swap(/.*)?'
# systemd-sleep stores its battery discharge-rate estimate in
# /var/lib/systemd/sleep, but SELinux lets it create files only inside that dir
# (systemd_sleep_var_lib_t), not create the dir itself under /var/lib/systemd.
# Nothing else creates it, so it would fall back to a fixed 1h estimate; have
# tmpfiles create it at boot, labelled from the policy's file contexts.
cat > /usr/lib/tmpfiles.d/systemd-sleep-state.conf <<'EOF'
# State dir for systemd-sleep's battery discharge-rate estimate; systemd-sleep
# itself is not allowed to create it.
d /var/lib/systemd/sleep 0755 root root -
EOF
# A mounted CIFS share can make every sleep fail: when the laptop wakes to
# hibernate, cifs background work (cifsiod, a freezable workqueue) blocks on the
# network that sleep took down, the kernel gives up freezing tasks after 20 s
# ("Device or resource busy"), and logind keeps retrying. So unmount CIFS shares
# before any sleep: -f aborts hung requests, -l detaches even if something is
# still inside. Automount units for them are stopped first, or gvfs re-triggers
# the mount within milliseconds of the unmount, and restarted after resume so
# the shares come back on first access. A no-op without CIFS mounts.
cat > /usr/libexec/cifs-sleep <<'EOF'
#!/bin/sh
# cifs-sleep pre|post: see unmount-cifs-around-sleep.service.
state=/run/cifs-sleep-automounts
case "$1" in
pre)
    : >"$state"
    findmnt -s -n -r -t cifs -o TARGET,OPTIONS | while read -r target opts; do
        case ",$opts," in
        *,x-systemd.automount,*)
            unit="$(systemd-escape -p --suffix=automount "$target")"
            if systemctl -q is-active "$unit" && systemctl stop "$unit"; then
                echo "$unit" >>"$state"
            fi
            ;;
        esac
    done
    umount -a -f -l -t cifs
    ;;
post)
    [ -s "$state" ] && xargs systemctl start <"$state"
    rm -f "$state"
    ;;
esac
exit 0
EOF
chmod 0755 /usr/libexec/cifs-sleep
# StopWhenUnneeded: ExecStop runs once sleep.target is left on resume.
cat > /usr/lib/systemd/system/unmount-cifs-around-sleep.service <<'EOF'
[Unit]
Description=Unmount CIFS shares before sleep, restore their automounts after
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/cifs-sleep pre
ExecStop=/usr/libexec/cifs-sleep post

[Install]
WantedBy=sleep.target
EOF
mkdir -p /usr/lib/systemd/system/sleep.target.wants
ln -sf ../unmount-cifs-around-sleep.service \
    /usr/lib/systemd/system/sleep.target.wants/unmount-cifs-around-sleep.service
install -m 0755 /tmp/enable-hibernation /usr/bin/enable-hibernation


### Rebuild the initramfs without nouveau
# Fedora's generic (no-hostonly) initramfs carries every DRM driver, and nouveau
# drags in all of linux-firmware's NVIDIA GSP blobs: ~106M of a ~238M image.
# ostree copies kernel + initramfs into /boot for every deployment, so on
# Fedora's default 1G /boot a third (e.g. pinned) deployment leaves no room for
# an upgrade, which then fails to finalize with ENOSPC. Without nouveau in the
# initramfs, NVIDIA machines lose only early KMS and the plymouth splash; nouveau
# still loads from the real root after switch-root. amdgpu/i915/xe and every
# dracut module stay. Runs after all package installs so the initramfs matches
# the final image. It logs a non-fatal "dracut-install: ERROR: installing
# '/root'": /root links to var/roothome, which exists only on a booted system.
KERNEL="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)"
cat > /usr/lib/dracut/dracut.conf.d/90-omit-nouveau.conf <<'EOF'
omit_drivers+=" nouveau "
EOF
DRACUT_NO_XATTR=1 dracut --no-hostonly --reproducible --add ostree \
    --kver "${KERNEL}" -f "/usr/lib/modules/${KERNEL}/initramfs.img"


### Build-time smoke test (fails the build if the image is broken)
/tmp/check-build.sh
