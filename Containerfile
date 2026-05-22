## 1. BUILD ARGS
# These allow changing the produced image by passing different build args to adjust
# the source from which your image is built.
# Build args can be provided on the commandline when building locally with:
#   podman build -f Containerfile --build-arg SOURCE_TAG=43 -t local-image

ARG SOURCE_REGISTRY="quay.io/fedora-ostree-desktops"
ARG SOURCE_IMAGE="sway-atomic"
ARG SOURCE_TAG="43"


### 2. SOURCE IMAGE
FROM ${SOURCE_REGISTRY}/${SOURCE_IMAGE}:${SOURCE_TAG}


### 3. MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

COPY build.sh /tmp/build.sh
COPY check-build.sh /tmp/check-build.sh

# Cosign public key used to verify this image's signatures (see build.sh, which
# wires up the registries.d + policy.json entries that consume it).
COPY cosign.pub /etc/pki/containers/sericea-main.pub

RUN mkdir -p /var/lib/alternatives && \
    /tmp/build.sh && \
    ostree container commit
## NOTES:
# - /var/lib/alternatives is required to prevent failure with some RPM installs
# - All RUN commands must end with ostree container commit
#   see: https://coreos.github.io/rpm-ostree/container/#using-ostree-container-commit
