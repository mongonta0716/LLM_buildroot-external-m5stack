# x86_64 Linux build environment for the AX630C Buildroot tree.
#
# This BR2_EXTERNAL tree ships prebuilt x86_64 Linux binaries (the
# aarch64-none-linux-gnu toolchain under toolchain/, and
# tools/bin/ax_gzip, img2simg, make_ext4fs) with no source included, so
# the build cannot run natively on macOS or on arm64 Linux. Building
# this image with --platform linux/amd64 on Apple Silicon lets Docker
# Desktop's Rosetta emulation run those binaries unmodified.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        debianutils sed make binutils build-essential gcc g++ bash patch \
        gzip bzip2 perl tar cpio unzip zip rsync file bc git \
        wget xz-utils flex bison libssl-dev libelf-dev libncurses-dev \
        python3 python3-pip locales ca-certificates sudo \
        cmake p7zip-full expect qemu-user-static android-sdk-libsparse-utils \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
