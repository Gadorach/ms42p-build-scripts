#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need readelf; need mkfs.jffs2; need xxd
IN="$STAGING/nor"; WORK="$BUILD/nor-pack"
LOADER="$IN/loader1.bin"; KELF="$IN/vmlinuz"; KBIN="$IN/vmlinuz.bin"; ROOTFS="$IN/rootfs.squashfs"
for f in "$LOADER" "$KELF" "$KBIN" "$ROOTFS"; do [[ -f "$f" ]] || die "Missing input: $f"; done
LOADER_REGION=$((0x40000)); KERNEL_REGION=$((0x2c0000)); ROOTFS_REGION=$((0x800000)); JFFS2_REGION=$((0x500000)); TOTAL=$((0x1000000))
[[ $(stat -c %s "$LOADER") -eq $LOADER_REGION ]] || die "Loader size is not 256 KiB"
ksize=$(stat -c %s "$KBIN"); rsize=$(stat -c %s "$ROOTFS")
(( ksize + 32 <= KERNEL_REGION )) || die "Kernel plus 32-byte header exceeds kernel region"
(( rsize > 0 && rsize <= ROOTFS_REGION )) || die "Rootfs size $rsize exceeds 8 MiB region"
entry=$(readelf -h "$KELF" | awk '/Entry point address/ {print $4}')
[[ "$entry" == 0x81000000 ]] || die "Expected compressed vmlinuz entry 0x81000000, got $entry"
rm -rf "$WORK"; mkdir -p "$WORK/jffs2-root/.upper/etc" "$WORK/jffs2-root/.work/etc" "$WORK/jffs2-root/.upper/root" "$WORK/jffs2-root/.work/root"
python3 - "$WORK/boot1-header.bin" "$ksize" <<'PY'
import struct, sys
out=sys.argv[1]; length=int(sys.argv[2])
with open(out,'wb') as f:
    f.write(b'SPIM')
    f.write(struct.pack('<I', 0x81000000))
    f.write(struct.pack('<I', length))
    f.write(struct.pack('<I', 0x81000000))
    f.write(b'\0'*16)
PY
cat "$WORK/boot1-header.bin" "$KBIN" > "$WORK/kernel.region"
truncate -s "$KERNEL_REGION" "$WORK/kernel.region"
cp "$ROOTFS" "$WORK/rootfs.region"; truncate -s "$ROOTFS_REGION" "$WORK/rootfs.region"
mkfs.jffs2 --pad="$JFFS2_REGION" -l -n -X lzo -x zlib -y 40:lzo -r "$WORK/jffs2-root" -o "$WORK/overlay.region"
name="ms42p-postmerkos-$(date -u +%Y%m%d-%H%M%S).bin"
cat "$LOADER" "$WORK/kernel.region" "$WORK/rootfs.region" "$WORK/overlay.region" > "$ARTIFACTS/$name"
[[ $(stat -c %s "$ARTIFACTS/$name") -eq $TOTAL ]] || die "Final image is not 16 MiB"
cp -f "$WORK/boot1-header.bin" "$WORK/kernel.region" "$WORK/rootfs.region" "$WORK/overlay.region" "$ARTIFACTS/"
sha256sum "$ARTIFACTS/$name" | tee "$ARTIFACTS/$name.sha256"
printf '%s\n' "$ARTIFACTS/$name" > "$ARTIFACTS/latest-image.txt"
log "Created $ARTIFACTS/$name"
