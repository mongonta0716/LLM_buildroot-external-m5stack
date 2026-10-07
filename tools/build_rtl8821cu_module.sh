#!/usr/bin/env bash
# Build and install morrownr/8821cu-20210916 into an image rootfs.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 BUILDROOT_OUTPUT ROOTFS" >&2
    exit 1
fi

BUILDROOT_OUTPUT="$(cd "$1" && pwd)"
ROOTFS="$(cd "$2" && pwd)"
KERNEL_SRC="$BUILDROOT_OUTPUT/build/linux-custom/build/linux-4.19.125"
KERNEL_RELEASE="$(cat "$KERNEL_SRC/include/config/kernel.release")"
HOST_DIR="$BUILDROOT_OUTPUT/host"
if [ "$KERNEL_RELEASE" != "4.19.125" ]; then
    echo "Expected kernel release 4.19.125, got $KERNEL_RELEASE" >&2
    exit 1
fi

# Pin both revision and archive checksum so subsequent image builds use
# the same driver. The cache is kept alongside the Buildroot output directory.
DRIVER_REVISION=bda65aac150d2cde0df9603206eec23a6f3b77c4
DRIVER_SHA256=73ceb08456344517e54b5344d03e4408b910144f5554198b511b1349eb9a623c
CACHE_DIR="$BUILDROOT_OUTPUT/../rtl8821cu-cache"
ARCHIVE="$CACHE_DIR/rtl8821cu-$DRIVER_REVISION.tar.gz"
SOURCE_DIR="$CACHE_DIR/rtl8821cu-$DRIVER_REVISION"
mkdir -p "$CACHE_DIR"
if [ ! -f "$ARCHIVE" ]; then
    wget -O "$ARCHIVE.tmp" "https://codeload.github.com/morrownr/8821cu-20210916/tar.gz/$DRIVER_REVISION"
    printf '%s  %s\n' "$DRIVER_SHA256" "$ARCHIVE.tmp" | sha256sum -c -
    mv "$ARCHIVE.tmp" "$ARCHIVE"
fi
printf '%s  %s\n' "$DRIVER_SHA256" "$ARCHIVE" | sha256sum -c -
if [ ! -f "$SOURCE_DIR/Makefile" ]; then
    mkdir -p "$SOURCE_DIR"
    tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"
fi

make_args=(ARCH=arm64
    "CROSS_COMPILE=$HOST_DIR/bin/aarch64-none-linux-gnu-"
    "KSRC=$KERNEL_SRC" "KVER=$KERNEL_RELEASE" LOCALVERSION=)
echo "Building rtl8821cu $DRIVER_REVISION for $KERNEL_RELEASE"
make -C "$SOURCE_DIR" "${make_args[@]}" clean
make -C "$SOURCE_DIR" -j"$(nproc)" "${make_args[@]}" modules

# Reject a module with different release or ABI flags before packaging.
module_magic="$(strings "$SOURCE_DIR/8821cu.ko" | sed -n 's/^vermagic=//p')"
reference="$(find "$BUILDROOT_OUTPUT/target/lib/modules/$KERNEL_RELEASE/kernel" -name '*.ko' -print -quit)"
kernel_magic="$(strings "$reference" | sed -n 's/^vermagic=//p')"
if [ -z "$module_magic" ] || [ "$module_magic" != "$kernel_magic" ]; then
    echo "rtl8821cu vermagic mismatch: $module_magic (kernel: $kernel_magic)" >&2
    exit 1
fi

install -D -m 0644 "$SOURCE_DIR/8821cu.ko" "$ROOTFS/lib/modules/$KERNEL_RELEASE/extra/8821cu.ko"
install -D -m 0644 "$SOURCE_DIR/LICENSE" "$ROOTFS/usr/share/doc/rtl8821cu/LICENSE"
printf 'Source: https://github.com/morrownr/8821cu-20210916\nCommit: %s\nKernel: %s\n' \
    "$DRIVER_REVISION" "$KERNEL_RELEASE" > "$ROOTFS/usr/share/doc/rtl8821cu/source.txt"
"$HOST_DIR/sbin/depmod" -b "$ROOTFS" "$KERNEL_RELEASE"

# Keep a visible build record and a copy of the compiled module in /root
# so a flashed ModuleLLM can be identified without changing uname -r.
install -D -m 0644 "$SOURCE_DIR/8821cu.ko" "$ROOTFS/root/8821cu.ko"
BUILD_TIME_JST="$(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S %z')"
KERNEL_SHA256="$(sha256sum "$BUILDROOT_OUTPUT/images/Image" | cut -d ' ' -f 1)"
MODULE_SHA256="$(sha256sum "$SOURCE_DIR/8821cu.ko" | cut -d ' ' -f 1)"
cat > "$ROOTFS/root/image-build-info.txt" <<EOF
Build time (JST): $BUILD_TIME_JST
Kernel release: $KERNEL_RELEASE
Kernel Image SHA256: $KERNEL_SHA256
RTL8821CU source: https://github.com/morrownr/8821cu-20210916
RTL8821CU commit: $DRIVER_REVISION
RTL8821CU vermagic: $module_magic
RTL8821CU module SHA256: $MODULE_SHA256
Installed module: /lib/modules/$KERNEL_RELEASE/extra/8821cu.ko
Module copy: /root/8821cu.ko
EOF
chmod 0644 "$ROOTFS/root/image-build-info.txt"
echo "Installed /lib/modules/$KERNEL_RELEASE/extra/8821cu.ko ($module_magic)"
echo "Saved /root/image-build-info.txt and /root/8821cu.ko"
