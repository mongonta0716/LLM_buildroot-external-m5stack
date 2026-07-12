#!/usr/bin/env bash
# Run a command inside an x86_64 Linux container for the AX630C
# Buildroot tree.
#
# Buildroot requires a Linux host, and this BR2_EXTERNAL tree bundles
# prebuilt x86_64 Linux binaries (toolchain/, tools/bin/ax_gzip,
# img2simg, make_ext4fs) that only run on x86_64 Linux. On Apple
# Silicon, Docker Desktop's Rosetta emulation runs the linux/amd64
# container transparently, so this lets you build without modifying
# the toolchain or vendor binaries.
#
# Layout expected on the host (buildroot cloned side-by-side with this
# BR2_EXTERNAL tree, as described in the top-level README.md):
#   <workspace>/buildroot/
#   <workspace>/LLM_buildroot-external-m5stack/   (this repo)
#
# Env vars:
#   M5STACK_DOCKER_WORKDIR     path under /work to cd into (default: buildroot)
#   M5STACK_DOCKER_PRIVILEGED  set to 1 to add --privileged (needed for
#                              scripts that chroot/mount, e.g. the
#                              creat_*_ubuntu22_04_image.sh tools)
#
# Note: this does not configure binfmt_misc/qemu. Do not attempt to
# mount or register binfmt_misc from inside the container yourself --
# on Docker Desktop it is not namespaced the way you'd expect, and
# doing so can corrupt the VM's own x86_64 (Rosetta) execution path,
# requiring "Troubleshoot > Clean / Purge data" to recover.
#
# Usage:
#   ./docker/build.sh                              # interactive shell in buildroot/
#   ./docker/build.sh make BR2_EXTERNAL=../LLM_buildroot-external-m5stack m5stack_module_llm_4_19_defconfig
#   ./docker/build.sh make

set -euo pipefail

IMAGE_TAG="m5stack-ax630c-buildroot:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTERNAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="$(cd "$EXTERNAL_DIR/.." && pwd)"

WORKDIR_IN_CONTAINER="${M5STACK_DOCKER_WORKDIR:-buildroot}"

if [[ "$WORKDIR_IN_CONTAINER" == "buildroot" && ! -d "$WORKSPACE_DIR/buildroot" ]]; then
    echo "warning: $WORKSPACE_DIR/buildroot not found." >&2
    echo "         Clone it side-by-side with this repo first, e.g.:" >&2
    echo "         git clone -b st/2023.02.10 https://github.com/bootlin/buildroot.git '$WORKSPACE_DIR/buildroot'" >&2
fi

if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon not reachable, trying to start Docker Desktop..." >&2
    open -a Docker 2>/dev/null || true
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    docker info >/dev/null 2>&1 || { echo "error: Docker daemon did not start in time" >&2; exit 1; }
fi

docker build --platform linux/amd64 -t "$IMAGE_TAG" "$SCRIPT_DIR"

# Seed the array with the always-present flags so it's never empty:
# macOS ships bash 3.2, which mishandles a genuinely empty array under
# `set -u`.
run_args=(--rm --platform linux/amd64 -v "$WORKSPACE_DIR:/work" -w "/work/$WORKDIR_IN_CONTAINER")

if [[ -t 0 && -t 1 ]]; then
    run_args+=(-it)
fi

if [[ "${M5STACK_DOCKER_PRIVILEGED:-0}" == "1" ]]; then
    run_args+=(--privileged)
    # macOS host volumes are case-insensitive, which silently breaks
    # packages that rely on case-sensitive filenames (e.g. ncurses'
    # terminfo tree, "a/ansi" vs "A/..."). Keep the buildroot/rootfs
    # scratch trees on native (case-sensitive) Docker volumes instead
    # of the bind-mounted host path.
    run_args+=(-v "m5stack-build-buildroot:/work/$WORKDIR_IN_CONTAINER/build_Module_LLM_buildroot")
    run_args+=(-v "m5stack-build-ubuntu2204:/work/$WORKDIR_IN_CONTAINER/build_Module_LLM_ubuntu22_04")
fi

docker run "${run_args[@]}" "$IMAGE_TAG" "${@:-bash}"
