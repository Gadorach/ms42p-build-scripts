#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
[[ -d "$OPENWRT_DIR" ]] || die "Run 02-fetch-sources.sh first"
log "Building OpenWrt toolchain/tools"
cd "$OPENWRT_DIR"
cp -f config-elemental-3.18 .config
make oldconfig
JOBS="${JOBS:-1}"
run_logged openwrt-build make -j"$JOBS" BOARD=elemental-3.18 OPENWRT_EXTRA_BOARD_SUFFIX=_3.18
[[ -x "${CROSS_COMPILE}gcc" ]] || die "Cross compiler was not produced at ${CROSS_COMPILE}gcc"
