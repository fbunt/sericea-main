#!/bin/bash
#
# Build-time smoke test, modeled on ublue-os/main's build_files/check-build.sh.
# Runs at the end of build.sh so a broken image fails the build before it is
# ever pushed or signed. Catches the most common breakage: a Fedora package
# rename/drop across major-version bumps silently leaving a tool out.

set -ouex pipefail

### 1. Critical packages must be present
IMPORTANT_PACKAGES=(
    # base session
    sway
    # media stack (RPMfusion swap must have taken)
    ffmpeg
    libavcodec-freeworld
    # project tools
    qemu-kvm
    virt-manager
    neovim
    # AppImage runtime (libfuse.so.2)
    fuse-libs
    # remote access daemon
    tailscale
)

missing=()
for pkg in "${IMPORTANT_PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "check-build: missing expected packages: ${missing[*]}" >&2
    exit 1
fi
# tailscaled must start at boot, or remote access is gone after a reboot.
test -L /usr/lib/systemd/system/multi-user.target.wants/tailscaled.service

### 2. Signature policy must be valid and enforcing (default: reject)
python3 - <<'PY'
import json, sys
p = json.load(open("/etc/containers/policy.json"))
default = p.get("default")
if default != [{"type": "reject"}]:
    sys.exit(f"check-build: policy.json default is {default!r}, expected [reject] "
             "(ostree-image-signed refuses a lone insecureAcceptAnything default)")
repo = "ghcr.io/fbunt/sericea-main"
rule = p.get("transports", {}).get("docker", {}).get(repo, [])
if not rule or rule[0].get("type") != "sigstoreSigned":
    sys.exit(f"check-build: no sigstoreSigned rule for {repo}")
PY

### 3. Default wallpaper was decoded to PNG (swaybg has no JXL loader)
if [ -e /usr/share/backgrounds/default.jxl ] && [ ! -f /usr/share/backgrounds/default.png ]; then
    echo "check-build: JXL default wallpaper present but no decoded default.png; swaybg will show no wallpaper" >&2
    exit 1
fi

### 4. CA trust bundles are rebuilt at boot
# Otherwise a local trust change freezes them across upgrades (see build.sh).
test -L /usr/lib/systemd/system/sysinit.target.wants/ca-trust-extract.service

### 5. emSign ECC Root CA - G3 is not trusted (compromised intermediates)
anchors="$(trust list --filter=ca-anchors)"
if grep -q 'label: emSign ECC Root CA - G3' <<<"$anchors" ||
    grep -q 'hkjOPQQDAwNpADBmAjEAvvNhzwIQHWSVB7gYboiFBS+DCBeQyh+KTOgNG3qxrdWB' \
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; then
    echo "check-build: emSign ECC Root CA - G3 is still trusted" >&2
    exit 1
fi

### 6. initramfs stays slim and still boots ostree
# ostree keeps one kernel + initramfs per deployment in /boot (see build.sh), so
# nouveau or another large firmware set creeping back would refill it; fail here
# instead of at an upgrade's finalize. List into a variable first so a failing
# lsinitrd aborts under set -e instead of reading as "no match"; tracing is off
# for that line because the listing runs to thousands of lines.
KERNEL="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)"
initrd="/usr/lib/modules/${KERNEL}/initramfs.img"
{ set +x; } 2>/dev/null
initrd_files="$(lsinitrd "${initrd}")"
set -x
if grep -q 'firmware/nvidia/' <<<"${initrd_files}"; then
    echo "check-build: nouveau's NVIDIA firmware is back in the initramfs" >&2
    exit 1
fi
# systemd-hibernate-resume (dracut's resume module) is what resumes from the
# HibernateLocation EFI variable; without it hibernation is a cold boot.
for want in usr/lib/ostree/ostree-prepare-root /drm/amd/amdgpu/amdgpu.ko \
    /drm/i915/i915.ko /drm/xe/xe.ko usr/lib/systemd/systemd-hibernate-resume; do
    if ! grep -qF "${want}" <<<"${initrd_files}"; then
        echo "check-build: initramfs is missing ${want}" >&2
        exit 1
    fi
done
# ~132M today; the ceiling leaves room for normal firmware growth.
initrd_max=$((160 * 1024 * 1024))
initrd_size="$(stat -c %s "${initrd}")"
if [ "${initrd_size}" -gt "${initrd_max}" ]; then
    echo "check-build: initramfs is ${initrd_size} bytes (limit ${initrd_max})" >&2
    exit 1
fi

### 7. Docker starts on demand from docker.socket, not at boot
# An idle dockerd + containerd from boot costs battery for nothing. The libvirt
# forward rules hang off docker.service (see build.sh); nothing in the image may
# enable docker.service or pull it in.
if [ ! -L /usr/lib/systemd/system/docker.service.wants/libvirt-docker-forward.service ]; then
    echo "check-build: libvirt-docker-forward.service is not wanted by docker.service" >&2
    exit 1
fi
if compgen -G '/usr/lib/systemd/system/*.wants/docker.service' >/dev/null ||
    grep -lE '^(Wants|Requires|BindsTo)=(.*[[:space:]])?docker\.service' \
        /usr/lib/systemd/system/*.service /usr/lib/systemd/system/*.target; then
    echo "check-build: docker.service is started at boot; it should start from docker.socket" >&2
    exit 1
fi

### 8. Suspend-then-hibernate pieces are in place (inert until enable-hibernation)
for f in /usr/lib/systemd/logind.conf.d/60-lid-suspend-then-hibernate.conf \
    /usr/lib/systemd/sleep.conf.d/60-hibernate-delay.conf \
    /usr/lib/systemd/system/var-swap-swapfile.swap \
    /usr/lib/tmpfiles.d/systemd-sleep-state.conf; do
    if [ ! -f "$f" ]; then
        echo "check-build: missing $f" >&2
        exit 1
    fi
done
# Without the condition the unit fails at every boot on machines with no file.
if ! grep -qx 'ConditionPathExists=/var/swap/swapfile' \
    /usr/lib/systemd/system/var-swap-swapfile.swap; then
    echo "check-build: var-swap-swapfile.swap is not conditioned on the swap file" >&2
    exit 1
fi
test -L /usr/lib/systemd/system/swap.target.wants/var-swap-swapfile.swap
test -x /usr/bin/enable-hibernation
# logind and systemd-sleep are denied a swap file that is not swapfile_t.
if [[ "$(matchpathcon -n /var/swap/swapfile)" != *:swapfile_t:* ]]; then
    echo "check-build: /var/swap/swapfile would not be labelled swapfile_t" >&2
    exit 1
fi

### 9. bootc image lint (warnings are non-fatal; real errors fail the build)
bootc container lint

### 10. Report the best-effort freeworld VA-API drivers (never fails)
# build.sh installs them only when RPMfusion has a build matching Fedora's mesa,
# so their absence is expected at times.
if rpm -q mesa-va-drivers-freeworld; then
    echo "check-build: mesa-va-drivers-freeworld installed (H.264/HEVC VA-API)"
else
    echo "check-build: WARNING: mesa-va-drivers-freeworld not installed; no H.264/HEVC VA-API"
fi

echo "check-build: all checks passed"
