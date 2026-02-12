# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

FROM ghcr.io/bootcrew/debian-bootc:latest

COPY system_files /

ARG DEBIAN_FRONTEND=noninteractive
# recreate directory structure required for apt
RUN --mount=type=bind,from=ctx,source=/,target=/ctx,rw \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=cache,dst=/var/lib/apt \
    --mount=type=cache,dst=/var/lib/dpkg/updates \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/install-bootloader && \
    /ctx/build && \
    /ctx/shared-scripts/build-initramfs && \
    /ctx/install-desktop KDE && \
    /ctx/shared-scripts/finalize

#RUN bash -c "rm -f /etc/{machine-id,hostname,locale.conf} || echo true"
#RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen && update-locale LANG=en_US.UTF-8
RUN passwd -d root && passwd -l root && sed -i 's/^root:[^:]*:/root::/' /etc/shadow
RUN bash -c "rm -f /etc/{machine-id,localtime,hostname,locale.conf} || echo true"

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
