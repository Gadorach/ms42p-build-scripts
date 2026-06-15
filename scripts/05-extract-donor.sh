#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need unsquashfs

DONOR_ROOT="$EXTRACTED/donor-rootfs"
DONOR_DOWNLOAD="$INPUTS/postmerkOS-20240818.bin"
ROOTFS_REGION_SIZE=$((0x800000))
FULL_IMAGE_SIZE=$((0x1000000))

find_input() {
  local n
  for n in good-rootfs.squashfs postmerkOS-20240818.bin donor-firmware.bin; do
    [[ -f "$INPUTS/$n" ]] && { printf '%s\n' "$INPUTS/$n"; return 0; }
  done
  return 1
}

download_donor() {
  local part="$DONOR_DOWNLOAD.part"
  log "No donor image found locally; downloading PostmerkOS reference release"
  log "Source: $DONOR_URL"
  rm -f "$part"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --retry-delay 2 --output "$part" "$DONOR_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --output-document="$part" "$DONOR_URL"
  else
    die "Neither curl nor wget is installed"
  fi
  [[ -s "$part" ]] || die "Downloaded donor image is empty"
  mv -f "$part" "$DONOR_DOWNLOAD"
}

DONOR="${DONOR_IMAGE:-$(find_input || true)}"
if [[ -z "$DONOR" ]]; then
  download_donor
  DONOR="$DONOR_DOWNLOAD"
fi
[[ -f "$DONOR" ]] || die "Donor input does not exist: $DONOR"

rm -rf "$DONOR_ROOT"
mkdir -p "$DONOR_ROOT"

case "$DONOR" in
  *.squashfs)
    ROOTFS_IMAGE="$DONOR"
    ;;
  *)
    donor_size="$(stat -c %s "$DONOR")"
    (( donor_size == FULL_IMAGE_SIZE )) || \
      die "Expected a 16 MiB donor firmware image, got $donor_size bytes: $DONOR"
    ROOTFS_IMAGE="$EXTRACTED/donor-rootfs-region.squashfs"
    dd if="$DONOR" of="$ROOTFS_IMAGE" bs=1M skip=3 count=8 status=progress
    [[ "$(stat -c %s "$ROOTFS_IMAGE")" -eq "$ROOTFS_REGION_SIZE" ]] || \
      die "Extracted donor rootfs region has the wrong size"
    ;;
esac

unsquashfs -f -d "$DONOR_ROOT" "$ROOTFS_IMAGE"
[[ -d "$DONOR_ROOT/etc" ]] || die "Donor /etc missing"
[[ -d "$DONOR_ROOT/lib/modules" ]] || die "Donor /lib/modules missing"
for f in elts_meraki.ko merakiclick.ko proclikefs.ko jaguar_dual/vc_click.ko jaguar_dual/vtss_core.ko; do
  [[ -f "$DONOR_ROOT/lib/modules/$f" ]] || die "Required donor module missing: $f"
done

find "$DONOR_ROOT/etc" -type f -printf '%P\n' | sort > "$EXTRACTED/donor-etc-files.txt"
find "$DONOR_ROOT/lib/modules" -type f -printf '%P\n' | sort > "$EXTRACTED/donor-module-files.txt"
sha256sum "$DONOR" > "$EXTRACTED/donor-input.sha256"
log "Donor rootfs extracted to $DONOR_ROOT"
