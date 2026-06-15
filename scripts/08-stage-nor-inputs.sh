#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need curl
rm -rf "$STAGING/nor"; mkdir -p "$STAGING/nor"
cp -f "$ARTIFACTS/kernel/vmlinuz" "$STAGING/nor/vmlinuz"
cp -f "$ARTIFACTS/kernel/vmlinuz.bin" "$STAGING/nor/vmlinuz.bin"
cp -f "$ARTIFACTS/rootfs/rootfs.squashfs" "$STAGING/nor/rootfs.squashfs"

case "${REDBOOT_SOURCE:-download}" in
  download)
    curl -fL --retry 3 "$REDBOOT_URL" -o "$STAGING/nor/loader1.bin.part"
    mv "$STAGING/nor/loader1.bin.part" "$STAGING/nor/loader1.bin"
    ;;
  donor)
    DONOR="${DONOR_IMAGE:-$INPUTS/postmerkOS-20240818.bin}"
    [[ -f "$DONOR" ]] || die "Donor full image missing: $DONOR"
    dd if="$DONOR" of="$STAGING/nor/loader1.bin" bs=64K count=4 status=none
    ;;
  file)
    [[ -f "${REDBOOT_FILE:-}" ]] || die "Set REDBOOT_FILE=/path/to/loader1"
    cp -f "$REDBOOT_FILE" "$STAGING/nor/loader1.bin"
    ;;
  *) die "REDBOOT_SOURCE must be download, donor, or file" ;;
esac
[[ $(stat -c %s "$STAGING/nor/loader1.bin") -eq 262144 ]] || die "loader1.bin must be exactly 262144 bytes"
sha256sum "$STAGING/nor"/* | tee "$STAGING/nor/SHA256SUMS"
