#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ -f "$BUILDROOT_DIR/.config" ]] || die "Run stage 06 first"

# Keep downloaded source archives outside the Buildroot output tree so clean
# rebuilds and future script runs can reuse them.
BUILDROOT_DL_DIR="${BUILDROOT_DL_DIR:-$PROJECT_ROOT/download-cache/buildroot}"
mkdir -p "$BUILDROOT_DL_DIR"

cd "$BUILDROOT_DIR"
if [[ "${CLEAN:-0}" == 1 ]]; then
  log "Cleaning Buildroot output; persistent download cache is retained"
  make clean
fi

log "Prefetching Buildroot sources from sources.buildroot.net first"
run_logged buildroot-download \
  make -j1 \
    BR2_DL_DIR="$BUILDROOT_DL_DIR" \
    BR2_PRIMARY_SITE="https://sources.buildroot.net" \
    source

log "Building root filesystem"
run_logged buildroot-build \
  make -j"${JOBS:-$(nproc)}" \
    BR2_DL_DIR="$BUILDROOT_DL_DIR" \
    BR2_PRIMARY_SITE="https://sources.buildroot.net"

ROOTFS="$BUILDROOT_DIR/output/images/rootfs.squashfs"
[[ -f "$ROOTFS" ]] || die "Buildroot did not produce rootfs.squashfs"
size=$(stat -c %s "$ROOTFS")
(( size > 0 && size <= 0x800000 )) || die "Rootfs size $size is outside 1..8388608 bytes"
mkdir -p "$ARTIFACTS/rootfs"
cp -f "$ROOTFS" "$ARTIFACTS/rootfs/rootfs.squashfs"
sha256sum "$ARTIFACTS/rootfs/rootfs.squashfs" | tee "$ARTIFACTS/rootfs/SHA256SUMS"
log "Buildroot download cache: $BUILDROOT_DL_DIR"
