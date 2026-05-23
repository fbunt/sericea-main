#!/bin/bash
#
# NVIDIA customization, layered on top of the base sericea-main image. Bakes the
# proprietary NVIDIA kernel module into the image at *build* time so nothing has
# to compile at boot on the atomic system. RPMfusion is already enabled by the
# base image's build.sh, so the akmod packages resolve here.

set -ouex pipefail

# Driver branch, as the akmod package suffix (akmod-${NVIDIA_DRIVER}):
#   nvidia-580xx  proprietary 580 legacy branch — the last to support Maxwell,
#                 Pascal and Volta. REQUIRED for the GTX 1070 (Pascal): RPMfusion's
#                 mainline akmod-nvidia is now 595, which dropped pre-Turing GPUs.
#   nvidia        mainline proprietary (Turing+ only as of the 595 branch).
#   nvidia-open   mainline open kernel modules (Turing+).
# Parameterized so a future Turing+/Blackwell card is a one-line CI swap.
NVIDIA_DRIVER="${NVIDIA_DRIVER:-nvidia-580xx}"

# Userspace driver+CUDA package name. Legacy branches carry the branch infix
# (xorg-x11-drv-nvidia-580xx-cuda); the -open kmod reuses mainline userspace.
case "${NVIDIA_DRIVER}" in
    nvidia | nvidia-open) CUDA_PKG="xorg-x11-drv-nvidia-cuda" ;;
    *)                    CUDA_PKG="xorg-x11-drv-${NVIDIA_DRIVER}-cuda" ;;
esac

NVIDIA_REPO="ghcr.io/fbunt/sericea-main-nvidia"

# The kmod MUST be compiled against the exact kernel baked into the base image,
# not whatever is newest in the repos, or it will not load at boot. Pin to it.
KERNEL="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)"
echo "build-nvidia: building ${NVIDIA_DRIVER} kmod for kernel ${KERNEL}"


### akmod build framework + matching kernel headers (phase 1)
# Install akmods FIRST, on its own, so its ostree auto-build hook can be
# neutralized BEFORE the driver's scriptlet fires. That hook (akmods-ostree-post,
# run by akmod-nvidia's %post) builds the kmod by calling akmodsbuild as root.
# akmodsbuild only tolerates root when /var is read-only — true in an rpm-ostree
# *compose*, but NOT in this podman/rpm-ostree-install build, where /var is
# writable so its guard aborts and fails the whole transaction. We build the
# module ourselves below instead.
#
# kernel-devel-${KERNEL} must match the baked kernel exactly. If a future base
# image's kernel has aged out of the main repos, this is the line that fails the
# build — pull kernel-devel from updates-archive (or the matching koji build).
rpm-ostree install akmods gcc make "kernel-devel-${KERNEL}"

cat > /usr/sbin/akmods-ostree-post <<'EOF'
#!/bin/sh
# Neutralized for in-container builds; build-nvidia.sh builds the kmod explicitly.
exit 0
EOF
chmod 0755 /usr/sbin/akmods-ostree-post


### Driver + CUDA + VAAPI bridge (phase 2; auto-build hook is now a no-op)
rpm-ostree install \
    "akmod-${NVIDIA_DRIVER}" \
    "${CUDA_PKG}" \
    libva-nvidia-driver


### Compile the kmod for the baked kernel (atomic image: nothing builds at runtime)
# akmodsbuild refuses to run where /var is writable, so run it as the
# unprivileged akmods user the package created — exactly how `akmods` invokes it —
# then extract the freshly built kmod straight into the image, mirroring what
# akmods-ostree-post does on a compose host (akmods' own dnf-install path is for
# traditional, non-ostree systems and doesn't apply here).
# Exactly one akmod branch is installed, so there is exactly one kmod srpm here;
# glob it rather than guessing the branch's infix naming.
shopt -s nullglob
kmodsrcs=(/usr/src/akmods/*-kmod-*.src.rpm)
if [ "${#kmodsrcs[@]}" -ne 1 ]; then
    echo "build-nvidia: expected exactly one kmod srpm in /usr/src/akmods, found ${#kmodsrcs[@]}" >&2
    exit 1
fi
builddir="$(mktemp -d)"
chown akmods:akmods "${builddir}"
runuser -u akmods -- /usr/sbin/akmodsbuild --quiet \
    --kernels "${KERNEL}" --outputdir "${builddir}" "${kmodsrcs[0]}"
for rpm in "${builddir}"/*.rpm; do
    case "${rpm}" in *debuginfo*|*debugsource*) continue ;; esac
    rpm2cpio "${rpm}" | cpio --quiet -idm -D /
done
rm -rf "${builddir}"

# A build that silently produced nothing must fail here, not ship a nouveau-only
# image that looks fine until first boot.
if ! find "/usr/lib/modules/${KERNEL}" -name 'nvidia.ko*' | grep -q .; then
    echo "build-nvidia: nvidia.ko was not produced for ${KERNEL}" >&2
    exit 1
fi
# Refresh the module dependency index so the freshly built kmod resolves at boot.
depmod -a "${KERNEL}"


### Disable nouveau, enable nvidia DRM modeset (required for Wayland/sway)
cat > /usr/lib/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

mkdir -p /usr/lib/bootc/kargs.d
cat > /usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOF'
kargs = [
    "rd.driver.blacklist=nouveau",
    "modprobe.blacklist=nouveau",
    "nvidia-drm.modeset=1",
]
EOF


### sway / wlroots on NVIDIA
# wlroots historically needs software cursors on the proprietary driver, and
# sway must be launched with --unsupported-gpu when wlroots flags the GPU. These
# are set globally so the session inherits them. VERIFY ON THE ACTUAL 1070:
# recent wlroots + driver 550+ may not need all of this; trim once confirmed.
mkdir -p /usr/lib/environment.d
cat > /usr/lib/environment.d/90-nvidia-wayland.conf <<'EOF'
# NVIDIA proprietary driver on wlroots/sway. Re-verify on hardware.
WLR_NO_HARDWARE_CURSORS=1
EOF


### Container signature verification — widen the base policy to the nvidia repo
# The base image's policy.json only trusts ghcr.io/fbunt/sericea-main. This layer
# is published as a separate repo, so add it to registries.d + policy.json. Same
# cosign key signs both (same owner), already at /etc/pki/containers/.
cat > /etc/containers/registries.d/sericea-main-nvidia.yaml <<EOF
docker:
  ${NVIDIA_REPO}:
    use-sigstore-attachments: true
EOF

python3 - "$NVIDIA_REPO" <<'PY'
import json, sys
repo = sys.argv[1]
path = "/etc/containers/policy.json"
p = json.load(open(path))
p.setdefault("transports", {}).setdefault("docker", {})[repo] = [{
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/sericea-main.pub",
    "signedIdentity": {"type": "matchRepository"},
}]
json.dump(p, open(path, "w"), indent=4)
PY


### Build-time smoke test (fails the build if the image is broken)
NVIDIA_DRIVER="${NVIDIA_DRIVER}" /tmp/check-build-nvidia.sh
