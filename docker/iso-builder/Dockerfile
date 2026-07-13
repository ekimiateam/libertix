FROM debian:trixie-20260623@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a

ARG DEBIAN_SNAPSHOT
ARG DEBIAN_SUITE

ENV DEBIAN_FRONTEND=noninteractive
ENV LIBERTIX_DEBIAN_SNAPSHOT=${DEBIAN_SNAPSHOT}
ENV LIBERTIX_DEBIAN_SUITE=${DEBIAN_SUITE}

RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources \
    && printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s/ %s main\n' \
        "$DEBIAN_SNAPSHOT" "$DEBIAN_SUITE" > /etc/apt/sources.list \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        debootstrap \
        dosfstools \
        git \
        grub-common \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        grub-pc-bin \
        initramfs-tools-core \
        isolinux \
        mtools \
        shim-signed \
        squashfs-tools \
        syslinux-common \
        util-linux \
        xorriso \
        zstd \
    && rm -rf /var/lib/apt/lists/*

COPY build-isos.sh /usr/local/bin/build-libertix-isos
COPY verify-built-iso.sh /usr/local/bin/verify-libertix-iso

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/build-libertix-isos"]
