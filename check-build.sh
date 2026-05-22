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
)

missing=()
for pkg in "${IMPORTANT_PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "check-build: missing expected packages: ${missing[*]}" >&2
    exit 1
fi

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

### 3. bootc image lint (warnings are non-fatal; real errors fail the build)
bootc container lint

echo "check-build: all checks passed"
