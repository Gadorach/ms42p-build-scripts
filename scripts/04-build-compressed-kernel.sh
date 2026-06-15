#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ -x "${CROSS_COMPILE}gcc" ]] || die "OpenWrt cross compiler missing; run stage 03"
log "Building compressed vmlinuz"
cd "$KERNEL_DIR"
if [[ "${CLEAN:-0}" == 1 ]]; then make ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" mrproper; fi
make ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" msxx_defconfig
make ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" prepare
run_logged kernel-build make -j"${JOBS:-$(nproc)}" ARCH=mips CROSS_COMPILE="$CROSS_COMPILE" vmlinuz
"${CROSS_COMPILE}objcopy" -O binary -S vmlinuz vmlinuz.bin
entry=$(readelf -h vmlinuz | awk '/Entry point address/ {print $4}')
[[ "$entry" == "0x81000000" ]] || die "Unexpected compressed-kernel entry point: $entry"
mkdir -p "$ARTIFACTS/kernel"
cp -f vmlinuz vmlinuz.bin "$ARTIFACTS/kernel/"
log "Creating local Buildroot Linux headers tarball"
rm -f "$KERNEL_HEADERS_TARBALL"
tar -C "$SWITCH_DIR" -cjf "$KERNEL_HEADERS_TARBALL" --transform='s|^linux-3.18|linux-3.18.123|' linux-3.18
sha256sum vmlinuz vmlinuz.bin "$KERNEL_HEADERS_TARBALL" | tee "$ARTIFACTS/kernel/SHA256SUMS"
