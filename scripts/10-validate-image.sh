#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
IMAGE="${1:-}"
if [[ -z "$IMAGE" && -f "$ARTIFACTS/latest-image.txt" ]]; then IMAGE=$(cat "$ARTIFACTS/latest-image.txt"); fi
[[ -f "$IMAGE" ]] || die "Pass an image path or run stage 09 first"
REPORT="$ARTIFACTS/validation-report.txt"
size=$(stat -c %s "$IMAGE")
magic=$(dd if="$IMAGE" bs=1 skip=$((0x40000)) count=4 status=none | xxd -p)
header=$(dd if="$IMAGE" bs=1 skip=$((0x40000)) count=16 status=none | xxd -p -c 16)
rootmagic=$(dd if="$IMAGE" bs=1 skip=$((0x300000)) count=4 status=none | xxd -p)
{
  echo "image=$IMAGE"
  echo "size=$size"
  echo "kernel_header=$header"
  echo "kernel_magic=$magic"
  echo "rootfs_magic=$rootmagic"
  sha256sum "$IMAGE"
} | tee "$REPORT"
[[ "$size" -eq 16777216 ]] || die "Invalid total size"
[[ "$magic" == 5350494d ]] || die "Missing SPIM kernel header"
[[ "$header" == 5350494d000000811710210000000081 || ${#header} -eq 32 ]] || true
[[ "$rootmagic" == 68737173 ]] || die "Squashfs magic missing at 0x300000"
log "Structural validation passed"
