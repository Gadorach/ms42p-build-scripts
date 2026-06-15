#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

scripts=(
  "$ROOT/package/fwupdate/files/common.sh"
  "$ROOT/package/fwupdate/files/fw_update"
  "$ROOT/package/fwupdate/files/fw_update_http"
  "$ROOT/package/fwupdate/files/fw_update_tftp"
  "$ROOT/package/fwupdate/files/fw_update_sftp"
  "$ROOT/package/fwupdate/files/fw_update_status"
)
for script in "${scripts[@]}"; do
  dash -n "$script"
done
bash -n "$ROOT/build-scripts/scripts/15-add-fwupdate-and-rebuild.sh"
bash -n "$ROOT/host/fwupdate-publish.sh"

gcc -static -Os -Wall -Wextra -Werror -std=c99 \
  -o "$TMP/fwflash" "$ROOT/package/fwupdate/fwflash.c"
file "$TMP/fwflash" | grep -qi 'statically linked'

truncate -s 16777216 "$TMP/test.bin"
"$ROOT/host/fwupdate-publish.sh" \
  "$TMP/test.bin" "$TMP/published" test-version "Host smoke test" >/dev/null
(
  cd "$TMP/published"
  sha256sum -c test.bin.sha256 >/dev/null
)
grep -q '^test-version|ms42p|test.bin|16777216|Host smoke test$' \
  "$TMP/published/index.tsv"

# Exercise status output and the helper's non-destructive preflight failure.
set +e
"$TMP/fwflash" --no-reboot \
  --rootfs-image "$TMP/test.bin" \
  --rootfs-mtd /dev/null \
  --rootfs-backup "$TMP/test.bin" \
  --status-file "$TMP/status.json" \
  --log-file "$TMP/flash.log" \
  --source host-test --firmware test.bin >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -q '"state":"error"' "$TMP/status.json"
grep -q '"source":"host-test"' "$TMP/status.json"

printf 'All host smoke tests passed. Hardware MTD flashing was not exercised.\n'
