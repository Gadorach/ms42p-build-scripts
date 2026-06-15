#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$HOME/meraki-ms42p-build}"
SOURCES="$PROJECT_ROOT/sources"
BUILD="$PROJECT_ROOT/build"
INPUTS="$PROJECT_ROOT/inputs"
EXTRACTED="$PROJECT_ROOT/extracted"
STAGING="$PROJECT_ROOT/staging"
ARTIFACTS="$PROJECT_ROOT/artifacts"
LOGS="$PROJECT_ROOT/logs"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SWITCH_DIR="$SOURCES/switch-11-22-ms220"
BUILDER_DIR="$SOURCES/meraki-builder"
HAL_BUILDER_DIR="$SOURCES/halmartin-meraki-builder"
CONFIG_STATUS_BUILDER_DIR="$SOURCES/hall-meraki-builder-config-status"
BUILDROOT_VERSION="2023.02.4"
BUILDROOT_DIR="$BUILD/buildroot-$BUILDROOT_VERSION"
OPENWRT_DIR="$SWITCH_DIR/openwrt"
KERNEL_DIR="$SWITCH_DIR/linux-3.18"
CROSS_COMPILE="$OPENWRT_DIR/staging_dir_mipsel_nofpu_3.18/bin/mipsel-linux-musl-"
KERNEL_HEADERS_TARBALL="$BUILD/linux-3.18.123.tar.bz2"

SWITCH_COMMIT="${SWITCH_COMMIT:-d167da8b01e46e29bf3347b8952ce9063ba75d29}"
BUILDER_COMMIT="${BUILDER_COMMIT:-fb8ed6af02c805ed9ae38542390042f4c6cfee14}"
SWITCH_REPO_URL="${SWITCH_REPO_URL:-https://github.com/halmartin/switch-11-22-ms220.git}"
BUILDER_REPO_URL="${BUILDER_REPO_URL:-https://github.com/hall/meraki-builder.git}"
HAL_BUILDER_REPO_URL="${HAL_BUILDER_REPO_URL:-https://github.com/halmartin/meraki-builder.git}"
HAL_BUILDER_REF="${HAL_BUILDER_REF:-master}"
CONFIG_STATUS_BUILDER_REPO_URL="${CONFIG_STATUS_BUILDER_REPO_URL:-https://github.com/hall/meraki-builder.git}"
CONFIG_STATUS_BUILDER_REF="${CONFIG_STATUS_BUILDER_REF:-config-status}"
DONOR_URL="${DONOR_URL:-https://watchmysys.com/files/meraki/ms220/postmerkOS-20240818.bin}"
REDBOOT_URL="${REDBOOT_URL:-https://github.com/halmartin/MS42-GPL-sources-3-18-122/raw/master/redboot/redboot-nocrc-sz.bin}"

mkdir -p "$SOURCES" "$BUILD" "$INPUTS" "$EXTRACTED" "$STAGING" "$ARTIFACTS" "$LOGS"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
run_logged() {
  local name="$1"; shift
  "$@" 2>&1 | tee "$LOGS/$name.log"
}
