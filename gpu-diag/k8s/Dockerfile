# ghcr.io/woodarddigital/gpu-diag — wrapper image for `kubectl debug node/…`
#
# Build from the gpu-diag/ directory so both the wrapper and a fallback copy
# of the script are in context:
#   docker build -f k8s/Dockerfile -t ghcr.io/woodarddigital/gpu-diag .
#
# busybox provides everything the wrapper needs: sh, wget (https), nsenter,
# chroot, tee, sha256sum, tar (for kubectl cp). The diagnostic itself runs on
# the node with the node's tools, so nothing else is installed here.
FROM busybox:1.36.1
ARG VERSION=dev
COPY k8s/entrypoint.sh /opt/gpu-diag/entrypoint.sh
# Fallback only: used when the current script cannot be downloaded from the repo.
COPY gpu-diag.sh /opt/gpu-diag/gpu-diag.sh
RUN chmod 0555 /opt/gpu-diag/entrypoint.sh /opt/gpu-diag/gpu-diag.sh \
    && printf '%s\n' "$VERSION" > /opt/gpu-diag/VERSION \
    && mkdir -p /output
# Keep the NVIDIA container runtime hook out of the way: this pod must start
# even when the node's driver is broken.
ENV NVIDIA_VISIBLE_DEVICES=void
WORKDIR /output
ENTRYPOINT ["/bin/sh", "/opt/gpu-diag/entrypoint.sh"]
