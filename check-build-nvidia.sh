#!/bin/bash
#
# Build-time smoke test for the NVIDIA layer, mirroring check-build.sh. Runs at
# the end of build-nvidia.sh so a broken GPU image fails the build before it is
# ever pushed or signed.

set -ouex pipefail

NVIDIA_DRIVER="${NVIDIA_DRIVER:-nvidia-580xx}"
KERNEL="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)"

case "${NVIDIA_DRIVER}" in
    nvidia | nvidia-open) CUDA_PKG="xorg-x11-drv-nvidia-cuda" ;;
    *)                    CUDA_PKG="xorg-x11-drv-${NVIDIA_DRIVER}-cuda" ;;
esac

### 1. Driver packages installed and the kmod actually built
rpm -q "akmod-${NVIDIA_DRIVER}" >/dev/null
rpm -q "${CUDA_PKG}" >/dev/null
ko="$(find "/usr/lib/modules/${KERNEL}" -name 'nvidia.ko*' | head -1)"
if [ -z "${ko}" ]; then
    echo "check-build-nvidia: nvidia.ko missing for ${KERNEL}" >&2
    exit 1
fi

### 1b. Built the requested variant (open vs proprietary)?
# The kmod spec auto-detects the GPU to choose open/proprietary; on a headless
# builder that picks OPEN, which silently breaks pre-Turing GPUs (Pascal etc.).
# Assert the module license matches the branch so a wrong variant fails the build
# here, not at the user's boot. proprietary = "NVIDIA", open = "Dual MIT/GPL".
lic="$(modinfo "${ko}" 2>/dev/null | sed -n 's/^license:[[:space:]]*//p')"
case "${NVIDIA_DRIVER}" in
    *-open) want="Dual MIT/GPL" ;;
    *)      want="NVIDIA" ;;
esac
if [ "${lic}" != "${want}" ]; then
    echo "check-build-nvidia: kmod license '${lic}' != expected '${want}' for ${NVIDIA_DRIVER} (open/proprietary mismatch)" >&2
    exit 1
fi

### 2. nouveau disabled and nvidia modeset karg present
grep -q '^blacklist nouveau' /usr/lib/modprobe.d/blacklist-nouveau.conf
grep -q 'nvidia-drm.modeset=1' /usr/lib/bootc/kargs.d/00-nvidia.toml

### 3. Signature policy still enforcing, and now trusts the nvidia repo
python3 - <<'PY'
import json, sys
p = json.load(open("/etc/containers/policy.json"))
if p.get("default") != [{"type": "reject"}]:
    sys.exit(f"check-build-nvidia: policy.json default is {p.get('default')!r}, expected [reject]")
for repo in ("ghcr.io/fbunt/sericea-main", "ghcr.io/fbunt/sericea-main-nvidia"):
    rule = p.get("transports", {}).get("docker", {}).get(repo, [])
    if not rule or rule[0].get("type") != "sigstoreSigned":
        sys.exit(f"check-build-nvidia: no sigstoreSigned rule for {repo}")
PY

### 4. bootc image lint (warnings are non-fatal; real errors fail the build)
bootc container lint

echo "check-build-nvidia: all checks passed"
