#!/usr/bin/env bash
set -Eeuo pipefail
# Buildroot image generation intentionally stops at rootfs.squashfs.
# Final NOR assembly is performed by scripts/09-pack-nor-image.sh.
: "${BINARIES_DIR:?BINARIES_DIR is required}"
[[ -f "$BINARIES_DIR/rootfs.squashfs" ]] || { echo "rootfs.squashfs missing" >&2; exit 1; }
printf 'Buildroot rootfs ready: %s (%s bytes)\n' "$BINARIES_DIR/rootfs.squashfs" "$(stat -c %s "$BINARIES_DIR/rootfs.squashfs")"
