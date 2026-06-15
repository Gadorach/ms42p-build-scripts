#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

need python3
need rsync
need unsquashfs
need file

[[ -d "$BUILDROOT_DIR" && -f "$BUILDROOT_DIR/.config" ]] || \
  die "Buildroot is not prepared. Run the normal build or web-UI stage first."

SRC="$SCRIPT_ROOT/support/fwupdate/package/fwupdate"
DST="$BUILDROOT_DIR/package/fwupdate"
[[ -f "$SRC/fwupdate.mk" && -f "$SRC/fwflash.c" ]] || \
  die "Firmware updater package payload is missing: $SRC"

log "Installing the fwupdate Buildroot package"
rm -rf "$DST"
rsync -a "$SRC/" "$DST/"

python3 - "$BUILDROOT_DIR/package/Config.in" <<'PY_REGISTER'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
line = 'source "package/fwupdate/Config.in"'
if line not in s:
    marker = 'source "package/flashrom/Config.in"'
    if marker in s:
        s = s.replace(marker, marker + '\n' + line, 1)
    else:
        s = s.rstrip() + '\n' + line + '\n'
p.write_text(s)
PY_REGISTER


log "Making generated firmware checksum sidecars updater-compatible"
PACKER="$SCRIPT_ROOT/scripts/09-pack-nor-image.sh"
[[ -f "$PACKER" ]] || die "NOR packer not found: $PACKER"
python3 - "$PACKER" <<'PY_PACKER'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'sha256sum "$ARTIFACTS/$name" | tee "$ARTIFACTS/$name.sha256"'
new = '(cd "$ARTIFACTS" && sha256sum "$name" > "$name.sha256")'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit("could not locate the checksum line in 09-pack-nor-image.sh")
p.write_text(s)
PY_PACKER

log "Enabling the static RAM flasher plus HTTP(S), TFTP and SFTP clients"
python3 - "$BUILDROOT_DIR/.config" <<'PY_CONFIG'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()

def enable(text, key):
    line = f'{key}=y'
    pat = rf'^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$'
    if re.search(pat, text, flags=re.M):
        return re.sub(pat, line, text, flags=re.M)
    return text.rstrip() + '\n' + line + '\n'

def disable(text, key):
    line = f'# {key} is not set'
    pat = rf'^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$'
    if re.search(pat, text, flags=re.M):
        return re.sub(pat, line, text, flags=re.M)
    return text.rstrip() + '\n' + line + '\n'

# Static libc archives are required only to build the small RAM-resident
# flasher. Shared libraries remain available for the normal root filesystem.
s = disable(s, 'BR2_SHARED_LIBS')
s = disable(s, 'BR2_STATIC_LIBS')
s = enable(s, 'BR2_SHARED_STATIC_LIBS')
s = enable(s, 'BR2_PACKAGE_FWUPDATE')
s = enable(s, 'BR2_PACKAGE_FWUPDATE_CURL')
# Explicit settings make the intended small TLS/SFTP stack reproducible.
for key in (
    'BR2_PACKAGE_MBEDTLS',
    'BR2_PACKAGE_LIBSSH2',
    'BR2_PACKAGE_LIBSSH2_MBEDTLS',
    'BR2_PACKAGE_LIBCURL',
    'BR2_PACKAGE_LIBCURL_CURL',
    'BR2_PACKAGE_LIBCURL_EXTRA_PROTOCOLS_FEATURES',
    'BR2_PACKAGE_LIBCURL_MBEDTLS',
    'BR2_PACKAGE_CA_CERTIFICATES',
):
    s = enable(s, key)
s = disable(s, 'BR2_PACKAGE_LIBCURL_VERBOSE')
s = disable(s, 'BR2_PACKAGE_LIBCURL_PROXY_SUPPORT')
s = disable(s, 'BR2_PACKAGE_LIBCURL_COOKIES_SUPPORT')
p.write_text(s)
PY_CONFIG

(
  cd "$BUILDROOT_DIR"
  make olddefconfig
)

for key in \
  BR2_SHARED_STATIC_LIBS \
  BR2_PACKAGE_FWUPDATE \
  BR2_PACKAGE_FWUPDATE_CURL \
  BR2_PACKAGE_LIBCURL \
  BR2_PACKAGE_LIBCURL_CURL \
  BR2_PACKAGE_LIBCURL_MBEDTLS \
  BR2_PACKAGE_LIBSSH2 \
  BR2_PACKAGE_LIBSSH2_MBEDTLS \
  BR2_PACKAGE_CA_CERTIFICATES; do
  grep -q "^$key=y$" "$BUILDROOT_DIR/.config" || die "Buildroot did not retain $key=y"
done

log "Clean rebuilding because the toolchain now also provides static libc archives"
CLEAN=1 "$SCRIPT_ROOT/scripts/07-build-rootfs.sh"

VERIFY_DIR="$BUILD/fwupdate-rootfs-check"
rm -rf "$VERIFY_DIR"
unsquashfs -quiet -d "$VERIFY_DIR" "$ARTIFACTS/rootfs/rootfs.squashfs"
required=(
  "$VERIFY_DIR/bin/fw_update"
  "$VERIFY_DIR/bin/fw_update_http"
  "$VERIFY_DIR/bin/fw_update_tftp"
  "$VERIFY_DIR/bin/fw_update_sftp"
  "$VERIFY_DIR/bin/fw_update_status"
  "$VERIFY_DIR/usr/libexec/fwupdate/fwflash"
  "$VERIFY_DIR/etc/fwupdate/sources.conf"
)
for f in "${required[@]}"; do [[ -e "$f" ]] || die "Updater file missing from rootfs: $f"; done
file "$VERIFY_DIR/usr/libexec/fwupdate/fwflash" | grep -qi 'statically linked' || \
  die "fwflash is not statically linked"

critical_commands=(curl mkfs.jffs2 hexdump sha256sum fuser mountpoint head dd awk sed killall umount)
for cmd in "${critical_commands[@]}"; do
  found=0
  for dir in bin sbin usr/bin usr/sbin; do
    if [[ -x "$VERIFY_DIR/$dir/$cmd" ]]; then found=1; break; fi
  done
  (( found == 1 )) || die "Required updater command is missing from rootfs: $cmd"
done

log "Repacking the NOR image with the updater-enabled rootfs"
"$SCRIPT_ROOT/scripts/08-stage-nor-inputs.sh"
"$SCRIPT_ROOT/scripts/09-pack-nor-image.sh"
"$SCRIPT_ROOT/scripts/10-validate-image.sh"

log "Firmware updater integration complete"
