#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need wget; need tar; need rsync; need python3
[[ -f "$KERNEL_HEADERS_TARBALL" ]] || die "Run stage 04 first"
[[ -d "$EXTRACTED/donor-rootfs" ]] || die "Run stage 05 first"
[[ -d "$HAL_BUILDER_DIR/buildroot" ]] || die "Hal Martin Buildroot source is missing. Run stage 02 again."

TARBALL="$BUILD/buildroot-$BUILDROOT_VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  wget -O "$TARBALL.part" "https://buildroot.org/downloads/buildroot-$BUILDROOT_VERSION.tar.gz"
  mv "$TARBALL.part" "$TARBALL"
fi
if [[ ! -d "$BUILDROOT_DIR" ]]; then
  tar -C "$BUILD" -xzf "$TARBALL"
fi

log "Overlaying Hal Martin's complete meraki-builder/buildroot tree"
rsync -a "$HAL_BUILDER_DIR/buildroot/" "$BUILDROOT_DIR/"

MS220_BOARD="$BUILDROOT_DIR/board/meraki/ms220"
[[ -f "$MS220_BOARD/buildroot-config" ]] || \
  die "Expected config missing after upstream overlay: $MS220_BOARD/buildroot-config"

log "Importing known-good donor /etc regular files and all /lib/modules"
mkdir -p "$MS220_BOARD/overlay/etc" "$MS220_BOARD/overlay/lib/modules"
rsync -a --delete --no-links "$EXTRACTED/donor-rootfs/etc/" "$MS220_BOARD/overlay/etc/"
rsync -a --delete "$EXTRACTED/donor-rootfs/lib/modules/" "$MS220_BOARD/overlay/lib/modules/"

install -m 0755 "$SCRIPT_ROOT/support/ms220/post-build.sh" "$MS220_BOARD/post-build.sh"
install -m 0755 "$SCRIPT_ROOT/support/ms220/post-image.sh" "$MS220_BOARD/post-image.sh"

cp -f "$MS220_BOARD/buildroot-config" "$BUILDROOT_DIR/.config"
python3 - "$BUILDROOT_DIR/.config" "$KERNEL_HEADERS_TARBALL" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
tar = pathlib.Path(sys.argv[2]).resolve()
s = p.read_text()

def set_config(text, key, value):
    line = f'{key}="{value}"'
    pattern = rf'^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$'
    if re.search(pattern, text, flags=re.M):
        return re.sub(pattern, line, text, flags=re.M)
    return text.rstrip() + '\n' + line + '\n'

s = set_config(s, 'BR2_KERNEL_HEADERS_CUSTOM_TARBALL_LOCATION', f'file://{tar}')
# Prefer Buildroot's long-lived source archive before package-specific upstream
# mirrors. Normal fallback remains enabled for anything absent from the archive.
s = set_config(s, 'BR2_PRIMARY_SITE', 'https://sources.buildroot.net')
s = set_config(s, 'BR2_ROOTFS_POST_BUILD_SCRIPT', 'board/meraki/ms220/post-build.sh')
s = set_config(s, 'BR2_ROOTFS_POST_IMAGE_SCRIPT', 'board/meraki/ms220/post-image.sh')
s = re.sub(r'^BR2_ROOTFS_POST_FAKEROOT_SCRIPT=.*$', 'BR2_ROOTFS_POST_FAKEROOT_SCRIPT=""', s, flags=re.M)
p.write_text(s)
PY

cd "$BUILDROOT_DIR"
make olddefconfig

{
  printf 'Buildroot %s\n' "$BUILDROOT_VERSION"
  printf 'halmartin/meraki-builder %s\n' "$(git -C "$HAL_BUILDER_DIR" rev-parse HEAD)"
  printf 'kernel headers %s\n' "$(sha256sum "$KERNEL_HEADERS_TARBALL" | awk '{print $1}')"
} > "$ARTIFACTS/buildroot-source-manifest.txt"

log "Buildroot 2023.02.4 prepared with upstream Buildroot integration, local kernel headers and donor overlay"
