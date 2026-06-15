#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

for cmd in curl git rsync python3 tar unsquashfs cmp comm sort find sha256sum; do
  need "$cmd"
done

[[ -d "$BUILDROOT_DIR" && -f "$BUILDROOT_DIR/.config" ]] || \
  die "Buildroot is not prepared. Complete stages 01 through 06 first."
[[ -d "$EXTRACTED/donor-rootfs" ]] || die "Donor rootfs is missing. Run stage 05 first."
[[ -f "$KERNEL_HEADERS_TARBALL" ]] || die "Kernel headers archive is missing. Run stage 04 first."

# This is now the authoritative web-management path. The branch can still be
# overridden for testing, but config-status is the default.
WEB_BUILDER_REF="${WEB_BUILDER_REF:-$CONFIG_STATUS_BUILDER_REF}"
WEB_BUILDER_REPO_URL="${WEB_BUILDER_REPO_URL:-$CONFIG_STATUS_BUILDER_REPO_URL}"
WEB_BUILDER_SOURCE_DIR="${WEB_BUILDER_SOURCE_DIR:-$CONFIG_STATUS_BUILDER_DIR}"
UI_REPO_URL="${UI_REPO_URL:-https://github.com/hall/postmerkos-ui.git}"
UI_REF="${UI_REF:-main}"
UI_DIR="${UI_DIR:-$SOURCES/postmerkos-ui}"
NODE_VERSION="${NODE_VERSION:-22.14.0}"
STARTUP_SCRIPT_POLICY="${STARTUP_SCRIPT_POLICY:-}"
CLICKSWSTATUS_POLICY="${CLICKSWSTATUS_POLICY:-}"

MS220_BOARD="$BUILDROOT_DIR/board/meraki/ms220"
OVERLAY="$MS220_BOARD/overlay"
DONOR_ROOT="$EXTRACTED/donor-rootfs"
REPORT="$ARTIFACTS/init-script-comparison.txt"

clone_ref() {
  local url="$1" dir="$2" ref="$3"
  if [[ ! -d "$dir/.git" ]]; then
    git clone "$url" "$dir"
  fi
  git -C "$dir" fetch origin "$ref" --tags
  if [[ "${ALLOW_DIRTY:-0}" != 1 ]] && [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    die "$dir has local changes. Commit/stash them or use ALLOW_DIRTY=1."
  fi
  git -C "$dir" checkout --detach FETCH_HEAD
}

select_node() {
  local major="0"
  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  fi
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 )) && command -v npm >/dev/null 2>&1; then
    return 0
  fi

  local machine node_arch archive tools
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) node_arch="x64" ;;
    aarch64|arm64) node_arch="arm64" ;;
    *) die "No suitable Node.js >=20 was found and architecture $machine is unsupported by the portable Node installer" ;;
  esac
  tools="$BUILD/tools"
  archive="$tools/node-v$NODE_VERSION-linux-$node_arch.tar.xz"
  mkdir -p "$tools"
  if [[ ! -f "$archive" ]]; then
    log "Downloading portable Node.js $NODE_VERSION for the postmerkOS UI build"
    curl -fL --retry 4 --retry-all-errors --connect-timeout 20 \
      "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$node_arch.tar.xz" \
      -o "$archive.part"
    mv "$archive.part" "$archive"
  fi
  if [[ ! -x "$tools/node-v$NODE_VERSION-linux-$node_arch/bin/node" ]]; then
    tar -C "$tools" -xJf "$archive"
  fi
  export PATH="$tools/node-v$NODE_VERSION-linux-$node_arch/bin:$PATH"
  command -v node >/dev/null 2>&1 || die "Portable Node.js installation failed"
  command -v npm >/dev/null 2>&1 || die "Portable npm installation failed"
}

choose_init_policy() {
  local answer
  case "${STARTUP_SCRIPT_POLICY,,}" in
    hall|hall-only|1) STARTUP_SCRIPT_POLICY="hall"; return ;;
    mixed|mix|2) STARTUP_SCRIPT_POLICY="mixed"; return ;;
    "") ;;
    *) die "STARTUP_SCRIPT_POLICY must be hall or mixed" ;;
  esac

  printf '\nStartup-script merge policy:\n'
  printf '  1) Hall only [default]\n'
  printf '     Exclude donor /etc/init.d files and use Hall config-status board scripts.\n'
  printf '  2) Mixed\n'
  printf '     Retain donor-only scripts, but overwrite every matching filename with Hall\x27s version.\n'
  printf '\nBuildroot package-provided scripts and the generated configd/uhttpd service scripts remain enabled in both modes.\n'
  if [[ -t 0 ]]; then
    read -r -p 'Select startup-script policy [1]: ' answer
  else
    answer=""
  fi
  case "${answer,,}" in
    ""|1|hall|hall-only) STARTUP_SCRIPT_POLICY="hall" ;;
    2|mixed|mix) STARTUP_SCRIPT_POLICY="mixed" ;;
    *) die "Invalid startup-script policy selection: $answer" ;;
  esac
}


choose_clickswstatus_policy() {
  local answer
  case "${CLICKSWSTATUS_POLICY,,}" in
    disabled|disable|skip|without|off|no|1)
      CLICKSWSTATUS_POLICY="disabled"
      return
      ;;
    enabled|enable|include|with|on|yes|2)
      CLICKSWSTATUS_POLICY="enabled"
      return
      ;;
    "") ;;
    *) die "CLICKSWSTATUS_POLICY must be disabled or enabled" ;;
  esac

  printf '\nStandalone clickswstatus utility:\n'
  printf '  1) Continue without /bin/clickswstatus [default]\n'
  printf '     Keep Hall\x27s default web stack: configd, pd690xx, uhttpd, and the UI.\n'
  printf '  2) Enable BR2_PACKAGE_STATUS=y\n'
  printf '     Build and require Hall\x27s standalone /bin/clickswstatus diagnostic utility.\n'
  if [[ -t 0 ]]; then
    read -r -p 'Select clickswstatus policy [1]: ' answer
  else
    answer=""
  fi
  case "${answer,,}" in
    ""|1|disabled|disable|skip|without|off|no) CLICKSWSTATUS_POLICY="disabled" ;;
    2|enabled|enable|include|with|on|yes) CLICKSWSTATUS_POLICY="enabled" ;;
    *) die "Invalid clickswstatus policy selection: $answer" ;;
  esac
}

normalize_clickswstatus_package() {
  local src="$BUILDROOT_DIR/package/clickswstatus"
  local dst="$BUILDROOT_DIR/package/status"

  [[ -d "$src" ]] || die "Hall clickswstatus package source is missing: $src"
  rm -rf "$dst"
  rsync -a "$src/" "$dst/"

  if [[ -f "$dst/clickswstatus.mk" ]]; then
    mv "$dst/clickswstatus.mk" "$dst/status.mk"
  fi
  [[ -f "$dst/status.mk" ]] || die "Could not normalize Hall's clickswstatus package recipe"

  # Hall's package uses STATUS_* variables and BR2_PACKAGE_STATUS, but the
  # directory/makefile name is clickswstatus. Buildroot derives the package
  # prefix from the .mk filename, so normalize it to package/status.
  sed -i -E 's|^STATUS_SITE[[:space:]]*=.*$|STATUS_SITE = package/status|' "$dst/status.mk"
  grep -q '^STATUS_SITE = package/status$' "$dst/status.mk" || \
    die "Could not rewrite STATUS_SITE for the normalized clickswstatus package"
  cat > "$dst/Config.in" <<'EOF_STATUS_CONFIG'
config BR2_PACKAGE_STATUS
    bool "clickswstatus"
    select BR2_PACKAGE_JSON_C
    help
      The clickswstatus utility reads switch status directly from the Click
      filesystem. It is optional because configd contains its own status
      implementation for the WebSocket interface.
EOF_STATUS_CONFIG

  rm -rf "$src"

  # package/Config.in is corrected by register_custom_packages immediately
  # afterward. Keep this function focused on the package files themselves.
  [[ -f "$dst/Config.in" && -f "$dst/status.mk" ]] || \
    die "Normalized status package is incomplete"
}

write_init_report() {
  local hall_init="$1" donor_init="$2" tmp hall_list donor_list common
  tmp="$(mktemp -d)"
  hall_list="$tmp/hall"
  donor_list="$tmp/donor"
  common="$tmp/common"
  find "$hall_init" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort -u > "$hall_list"
  find "$donor_init" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort -u > "$donor_list"
  comm -12 "$hall_list" "$donor_list" > "$common"

  {
    printf 'Hall meraki-builder ref: %s\n' "$WEB_BUILDER_REF"
    printf 'Hall meraki-builder commit: %s\n' "$(git -C "$WEB_BUILDER_SOURCE_DIR" rev-parse HEAD)"
    printf 'Selected policy: %s\n\n' "$STARTUP_SCRIPT_POLICY"
    printf '[Hall init.d scripts]\n'; cat "$hall_list" || true
    printf '\n[Donor init.d scripts]\n'; cat "$donor_list" || true
    printf '\n[Matching filenames; Hall wins in both policies]\n'; cat "$common" || true
    printf '\n[Matching files with different contents]\n'
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! cmp -s "$hall_init/$name" "$donor_init/$name"; then printf '%s\n' "$name"; fi
    done < "$common"
    printf '\n[Donor-only scripts retained only by mixed policy]\n'
    comm -13 "$hall_list" "$donor_list" || true
    printf '\n[Hall-only scripts]\n'
    comm -23 "$hall_list" "$donor_list" || true
  } > "$REPORT"
  rm -rf "$tmp"
  cat "$REPORT"
}

register_custom_packages() {
  python3 - "$BUILDROOT_DIR/package/Config.in" <<'PY_REGISTER_PACKAGES'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Hall's branch registers the original directory name. The local normalization
# renames that package to status so its directory, .mk filename, Kconfig symbol,
# and STATUS_* variable prefix agree. Canonicalize the Kconfig source path too;
# otherwise Kconfig aborts even when BR2_PACKAGE_STATUS is disabled.
s = s.replace(
    'source "package/clickswstatus/Config.in"',
    'source "package/status/Config.in"',
)

def dedupe_source_lines(text):
    seen = set()
    out = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('source "package/') and stripped.endswith('/Config.in"'):
            if stripped in seen:
                continue
            seen.add(stripped)
        out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")

def add_after(text, marker, lines):
    missing = [line for line in lines if line not in text]
    if not missing:
        return text
    block = marker + "\n" + "\n".join(missing)
    if marker in text:
        return text.replace(marker, block, 1)
    return text.rstrip() + "\n" + "\n".join(missing) + "\n"

s = dedupe_source_lines(s)
s = add_after(s, 'source "package/chrony/Config.in"', [
    'source "package/click/Config.in"',
    'source "package/status/Config.in"',
    'source "package/configd/Config.in"',
])
s = add_after(s, 'source "package/z3/Config.in"', [
    'source "package/find_hdr/Config.in"',
])
s = add_after(s, 'source "package/ytree/Config.in"', [
    'source "package/pd690xx/Config.in"',
])
s = dedupe_source_lines(s)
p.write_text(s)
PY_REGISTER_PACKAGES

  if grep -qF 'source "package/clickswstatus/Config.in"' "$BUILDROOT_DIR/package/Config.in"; then
    die "Stale package/clickswstatus Kconfig source remains after package normalization"
  fi
  grep -qF 'source "package/status/Config.in"' "$BUILDROOT_DIR/package/Config.in" || \
    die "Normalized package/status Kconfig source was not registered"
  [[ -f "$BUILDROOT_DIR/package/status/Config.in" ]] || \
    die "Normalized package/status/Config.in is missing"
}

patch_configd_if_needed() {
  local click_port="$BUILDROOT_DIR/package/configd/click_port.c"
  local websocket="$BUILDROOT_DIR/package/configd/websocket.c"
  [[ -f "$click_port" ]] || die "config-status configd source is missing: $click_port"
  python3 - "$click_port" "$websocket" "$ARTIFACTS/configd-compatibility-patch.txt" <<'PY'
from pathlib import Path
import sys
click_port = Path(sys.argv[1])
websocket = Path(sys.argv[2])
report = Path(sys.argv[3])
s = click_port.read_text()
needle = 'static struct json_object *read_storm_control(int port)'
start = s.find(needle)
status = 'not required: read_storm_control() no longer references dump_port_storm_control'
if start >= 0:
    brace = s.find('{', start)
    if brace < 0:
        raise SystemExit('Malformed read_storm_control() function')
    depth = 0
    end = None
    for i in range(brace, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit('Could not find end of read_storm_control()')
    old = s[start:end]
    if 'dump_port_storm_control' in old and 'OLDER_POSTMERKOS_CLICK_COMPAT' not in old:
        replacement = '''static struct json_object *read_storm_control(int port) {
  const char *handler = "/click/switch_port_table/dump_port_storm_control";

  /* OLDER_POSTMERKOS_CLICK_COMPAT:
   * Released PostmerkOS Click graphs expose set_port_storm_control but not
   * dump_port_storm_control. Keep configd alive and default the unreadable
   * initial state to enabled. */
  if (access(handler, R_OK) != 0) {
    fprintf(stderr,
            "warning: %s is unavailable; defaulting storm control to enabled\\n",
            handler);
    return json_object_new_boolean(true);
  }

  char *line = read_switch_port_table("dump_port_storm_control", port);
  if (!line)
    return json_object_new_boolean(true);
  const char *val = get_field(line, 2);
  bool enabled = !val || strcmp(val, "true") == 0;
  free(line);
  return json_object_new_boolean(enabled);
}'''
        s = s[:start] + replacement + s[end:]
        if '#include <unistd.h>' not in s:
            s = '#include <unistd.h>\n' + s
        click_port.write_text(s)
        status = 'applied: current upstream still calls the unavailable dump_port_storm_control handler'
    elif 'OLDER_POSTMERKOS_CLICK_COMPAT' in old or ('access(' in old and 'dump_port_storm_control' in old):
        status = 'already present upstream or from an earlier run'

if websocket.exists():
    ws = websocket.read_text()
    if 'difftime(' in ws and '#include <time.h>' not in ws:
        websocket.write_text('#include <time.h>\n' + ws)

report.write_text(status + '\n')
print(status)
PY
}

install_generated_service_scripts() {
  local init_dir="$OVERLAY/etc/init.d"
  mkdir -p "$init_dir"

  if ! grep -RqsE '(^|[ /])configd([[:space:]]|$)' "$init_dir"; then
    cat > "$init_dir/S15configd" <<'INIT'
#!/bin/sh
DAEMON=/bin/configd
PIDFILE=/var/run/configd.pid
LOGFILE=/tmp/configd.log
CONFIG=/etc/switch.json
start() {
    printf 'Starting configd: '
    [ -x "$DAEMON" ] || { echo 'FAIL (missing /bin/configd)'; return 1; }
    [ -d /click ] || { echo 'FAIL (/click is unavailable)'; return 1; }
    [ -e "$CONFIG" ] && [ ! -s "$CONFIG" ] && rm -f "$CONFIG"
    : >"$LOGFILE"
    rm -f "$PIDFILE"
    start-stop-daemon -S -q -b -m -p "$PIDFILE" -x "$DAEMON" -- \
        -c "$CONFIG" -w 4001 -p 3 >>"$LOGFILE" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo FAIL; cat "$LOGFILE"; return "$rc"; }
    sleep 2
    if [ ! -s "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo 'FAIL (configd exited during startup)'
        cat "$LOGFILE"
        rm -f "$PIDFILE"
        return 1
    fi
    echo OK
}
stop() {
    printf 'Stopping configd: '
    if [ ! -s "$PIDFILE" ]; then echo 'not running'; return 0; fi
    start-stop-daemon -K -q -p "$PIDFILE" -x "$DAEMON"
    rc=$?; rm -f "$PIDFILE"
    [ "$rc" -eq 0 ] && echo OK || echo FAIL
    return "$rc"
}
case "$1" in
    start) start ;;
    stop) stop ;;
    restart|reload) stop; sleep 1; start ;;
    status) [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
INIT
    chmod 0755 "$init_dir/S15configd"
  fi

  if ! grep -RqsE '(^|[ /])uhttpd([[:space:]]|$)' "$init_dir"; then
    cat > "$init_dir/S16uhttpd" <<'INIT'
#!/bin/sh
DAEMON=/usr/bin/uhttpd
PIDFILE=/var/run/uhttpd.pid
WEBROOT=/www
LOGFILE=/tmp/uhttpd.log
start() {
    printf 'Starting postmerkOS web interface: '
    [ -x "$DAEMON" ] || { echo 'FAIL (missing /usr/bin/uhttpd)'; return 1; }
    [ -f "$WEBROOT/index.html" ] || { echo 'FAIL (missing /www/index.html)'; return 1; }
    : >"$LOGFILE"
    rm -f "$PIDFILE"
    start-stop-daemon -S -q -b -m -p "$PIDFILE" -x "$DAEMON" -- \
        -f -p 0.0.0.0:80 -h "$WEBROOT" >>"$LOGFILE" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && echo OK || { echo FAIL; cat "$LOGFILE"; }
    return "$rc"
}
stop() {
    printf 'Stopping postmerkOS web interface: '
    if [ ! -s "$PIDFILE" ]; then echo 'not running'; return 0; fi
    start-stop-daemon -K -q -p "$PIDFILE" -x "$DAEMON"
    rc=$?; rm -f "$PIDFILE"
    [ "$rc" -eq 0 ] && echo OK || echo FAIL
    return "$rc"
}
case "$1" in
    start) start ;;
    stop) stop ;;
    restart|reload) stop; sleep 1; start ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
INIT
    chmod 0755 "$init_dir/S16uhttpd"
  fi
}

log "Fetching Hall meraki-builder branch $WEB_BUILDER_REF"
clone_ref "$WEB_BUILDER_REPO_URL" "$WEB_BUILDER_SOURCE_DIR" "$WEB_BUILDER_REF"
WEB_BUILDER_COMMIT="$(git -C "$WEB_BUILDER_SOURCE_DIR" rev-parse HEAD)"
[[ -d "$WEB_BUILDER_SOURCE_DIR/buildroot/board/meraki/ms220" ]] || \
  die "The selected branch does not contain the MS220 Buildroot integration"

log "Fetching hall/postmerkos-ui branch $UI_REF"
clone_ref "$UI_REPO_URL" "$UI_DIR" "$UI_REF"
UI_COMMIT="$(git -C "$UI_DIR" rev-parse HEAD)"
select_node
log "Building postmerkOS UI directly from the $UI_REF branch"
(
  cd "$UI_DIR"
  npm_config_cache="$BUILD/npm-cache" npm ci --no-audit --no-fund
  npm run build
)
[[ -f "$UI_DIR/build/index.html" ]] || die "postmerkOS UI build did not produce build/index.html"

log "Overlaying Hall's complete $WEB_BUILDER_REF Buildroot integration"
rsync -a "$WEB_BUILDER_SOURCE_DIR/buildroot/" "$BUILDROOT_DIR/"

# Hall stores custom packages under buildroot/packages/, while upstream
# Buildroot expects package/. Copy every branch package into the actual
# Buildroot package tree before registering its Config.in entry.
if [[ -d "$WEB_BUILDER_SOURCE_DIR/buildroot/packages" ]]; then
  for src in "$WEB_BUILDER_SOURCE_DIR"/buildroot/packages/*; do
    [[ -d "$src" ]] || continue
    name="$(basename "$src")"
    rm -rf "$BUILDROOT_DIR/package/$name"
    rsync -a "$src/" "$BUILDROOT_DIR/package/$name/"
  done
fi
normalize_clickswstatus_package
[[ -f "$MS220_BOARD/buildroot-config" ]] || die "config-status buildroot-config is missing"

HALL_OVERLAY_SRC="$WEB_BUILDER_SOURCE_DIR/buildroot/board/meraki/ms220/overlay"
HALL_INIT_SRC="$HALL_OVERLAY_SRC/etc/init.d"
DONOR_INIT_SRC="$DONOR_ROOT/etc/init.d"
[[ -d "$HALL_INIT_SRC" ]] || die "Hall init.d source is missing: $HALL_INIT_SRC"
[[ -d "$DONOR_INIT_SRC" ]] || die "Donor init.d source is missing: $DONOR_INIT_SRC"
choose_init_policy
choose_clickswstatus_policy
write_init_report "$HALL_INIT_SRC" "$DONOR_INIT_SRC"
printf '%s\n' "$CLICKSWSTATUS_POLICY" > "$ARTIFACTS/clickswstatus-policy.txt"

log "Reconstructing the board overlay; Hall files take precedence over donor files"
rm -rf "$OVERLAY"
mkdir -p "$OVERLAY/etc" "$OVERLAY/lib/modules"
if [[ "$STARTUP_SCRIPT_POLICY" == "hall" ]]; then
  rsync -a --no-links --exclude='/init.d/***' "$DONOR_ROOT/etc/" "$OVERLAY/etc/"
else
  rsync -a --no-links "$DONOR_ROOT/etc/" "$OVERLAY/etc/"
fi
rsync -a --delete "$DONOR_ROOT/lib/modules/" "$OVERLAY/lib/modules/"
# Copy the complete Hall overlay last. This replaces matching donor config and
# init files, including the newer config-status Click configuration data.
rsync -a "$HALL_OVERLAY_SRC/" "$OVERLAY/"

log "Installing the UI generated from hall/postmerkos-ui $UI_REF at /www"
rm -rf "$OVERLAY/www"
mkdir -p "$OVERLAY/www"
rsync -a --delete "$UI_DIR/build/" "$OVERLAY/www/"
find "$OVERLAY/www" -type d -exec chmod 0755 {} +
find "$OVERLAY/www" -type f -exec chmod 0644 {} +

register_custom_packages
patch_configd_if_needed
install_generated_service_scripts

# Keep the known-good post-build/post-image behavior from the v5 workflow.
install -m 0755 "$SCRIPT_ROOT/support/ms220/post-build.sh" "$MS220_BOARD/post-build.sh"
install -m 0755 "$SCRIPT_ROOT/support/ms220/post-image.sh" "$MS220_BOARD/post-image.sh"

log "Using Hall's config-status Buildroot configuration with local reproducibility fixes"
cp -f "$MS220_BOARD/buildroot-config" "$BUILDROOT_DIR/.config"
python3 - "$BUILDROOT_DIR/.config" "$KERNEL_HEADERS_TARBALL" "$CLICKSWSTATUS_POLICY" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
tar = Path(sys.argv[2]).resolve()
clickswstatus_policy = sys.argv[3]
s = p.read_text()

def set_string(text, key, value):
    line = f'{key}="{value}"'
    pat = rf'^(?:{re.escape(key)}=.*|# {re.escape(key)} is not set)$'
    if re.search(pat, text, flags=re.M):
        return re.sub(pat, line, text, flags=re.M)
    return text.rstrip() + '\n' + line + '\n'

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

s = set_string(s, 'BR2_KERNEL_HEADERS_CUSTOM_TARBALL_LOCATION', f'file://{tar}')
s = set_string(s, 'BR2_PRIMARY_SITE', 'https://sources.buildroot.net')
s = set_string(s, 'BR2_ROOTFS_OVERLAY', 'board/meraki/ms220/overlay')
s = set_string(s, 'BR2_ROOTFS_POST_BUILD_SCRIPT', 'board/meraki/ms220/post-build.sh')
s = set_string(s, 'BR2_ROOTFS_POST_IMAGE_SCRIPT', 'board/meraki/ms220/post-image.sh')
s = set_string(s, 'BR2_ROOTFS_POST_FAKEROOT_SCRIPT', '')
for key in (
    'BR2_PACKAGE_CONFIGD',
    'BR2_PACKAGE_PD690XX',
    'BR2_PACKAGE_UHTTPD',
):
    s = enable(s, key)
if clickswstatus_policy == 'enabled':
    s = enable(s, 'BR2_PACKAGE_STATUS')
else:
    s = disable(s, 'BR2_PACKAGE_STATUS')
p.write_text(s)
PY

(
  cd "$BUILDROOT_DIR"
  make olddefconfig
)
for key in BR2_PACKAGE_CONFIGD BR2_PACKAGE_PD690XX BR2_PACKAGE_UHTTPD; do
  grep -q "^$key=y$" "$BUILDROOT_DIR/.config" || die "Buildroot did not retain $key=y"
done
if [[ "$CLICKSWSTATUS_POLICY" == "enabled" ]]; then
  grep -q '^BR2_PACKAGE_STATUS=y$' "$BUILDROOT_DIR/.config" || \
    die "Buildroot did not retain BR2_PACKAGE_STATUS=y"
else
  if grep -q '^BR2_PACKAGE_STATUS=y$' "$BUILDROOT_DIR/.config"; then
    die "BR2_PACKAGE_STATUS remained enabled despite the disabled selection"
  fi
fi

cat > "$ARTIFACTS/webui-source-manifest.txt" <<EOF2
hall/meraki-builder ref: $WEB_BUILDER_REF
hall/meraki-builder commit: $WEB_BUILDER_COMMIT
hall/postmerkos-ui ref: $UI_REF
hall/postmerkos-ui commit: $UI_COMMIT
startup-script policy: $STARTUP_SCRIPT_POLICY
standalone clickswstatus: $CLICKSWSTATUS_POLICY
configd compatibility: $(cat "$ARTIFACTS/configd-compatibility-patch.txt")
UI source: built from Git main checkout, not a release archive
web root: /www
configd websocket port: 4001
uhttpd port: 80
EOF2

log "Performing a clean Buildroot rebuild so removed donor startup scripts cannot survive in output/target"
CLEAN=1 "$SCRIPT_ROOT/scripts/07-build-rootfs.sh"

VERIFY_DIR="$BUILD/webui-rootfs-check"
rm -rf "$VERIFY_DIR"
unsquashfs -quiet -d "$VERIFY_DIR" "$ARTIFACTS/rootfs/rootfs.squashfs"
required_files=(
  "$VERIFY_DIR/www/index.html"
  "$VERIFY_DIR/bin/configd"
  "$VERIFY_DIR/bin/pd690xx"
  "$VERIFY_DIR/usr/bin/uhttpd"
)
if [[ "$CLICKSWSTATUS_POLICY" == "enabled" ]]; then
  required_files+=("$VERIFY_DIR/bin/clickswstatus")
fi
for required in "${required_files[@]}"; do
  [[ -e "$required" ]] || die "Web UI rootfs verification failed; missing $required"
done
if [[ "$CLICKSWSTATUS_POLICY" == "disabled" && -e "$VERIFY_DIR/bin/clickswstatus" ]]; then
  log "Note: /bin/clickswstatus is present even though the standalone utility was not requested"
fi

# Validate Hall's board startup scripts after Buildroot's documented
# post-build transformations. Most scripts must remain byte-for-byte identical.
# S14passwd is intentionally changed by post-build.sh: the __SALT__ placeholder
# is replaced with the salt from the generated root account hash.
INIT_VALIDATION_REPORT="$ARTIFACTS/init-script-validation.txt"
: > "$INIT_VALIDATION_REPORT"
while IFS= read -r hall_script; do
  name="$(basename "$hall_script")"
  rootfs_script="$VERIFY_DIR/etc/init.d/$name"
  [[ -f "$rootfs_script" ]] || die "Missing Hall init script in rootfs: $name"
  [[ -x "$rootfs_script" ]] || die "Rootfs init script is not executable: $name"

  if grep -qF '__SALT__' "$hall_script"; then
    [[ -f "$VERIFY_DIR/etc/shadow" ]] || \
      die "Cannot validate $name because /etc/shadow is missing from the rootfs"

    validation_result="$(python3 - "$hall_script" "$rootfs_script" "$VERIFY_DIR/etc/shadow" \
      "$ARTIFACTS/init-script-$name.diff" <<'PY_VALIDATE_INIT'
from pathlib import Path
import difflib
import sys

source_path = Path(sys.argv[1])
actual_path = Path(sys.argv[2])
shadow_path = Path(sys.argv[3])
diff_path = Path(sys.argv[4])

salt = None
for line in shadow_path.read_text(errors='replace').splitlines():
    if line.startswith('root:'):
        fields = line.split(':', 2)
        password = fields[1] if len(fields) > 1 else ''
        parts = password.split('$')
        if len(parts) >= 4 and parts[2]:
            salt = parts[2]
        break

if not salt:
    print('ERROR:no-root-password-salt')
    raise SystemExit(0)

source = source_path.read_text(errors='surrogateescape')
actual = actual_path.read_text(errors='surrogateescape')
expected = source.replace('__SALT__', salt)

if actual == expected:
    print(f'OK:placeholder-replaced:{salt}')
    raise SystemExit(0)

# Record a useful diagnostic while keeping the terminal output concise.
diff = ''.join(difflib.unified_diff(
    expected.splitlines(keepends=True),
    actual.splitlines(keepends=True),
    fromfile=f'{source_path.name} (expected after post-build)',
    tofile=f'{actual_path.name} (rootfs)',
))
diff_path.write_text(diff or 'Files differ, but no textual diff could be generated.\n')
print(f'ERROR:mismatch:{diff_path}')
PY_VALIDATE_INIT
)"

    case "$validation_result" in
      OK:placeholder-replaced:*)
        printf '%s: matched Hall source after expected post-build salt substitution\n' \
          "$name" >> "$INIT_VALIDATION_REPORT"
        ;;
      ERROR:no-root-password-salt)
        die "Could not extract the root password salt needed to validate $name"
        ;;
      ERROR:mismatch:*)
        diff_file="${validation_result#ERROR:mismatch:}"
        die "Rootfs init script $name differs beyond the expected salt substitution; see $diff_file"
        ;;
      *)
        die "Unexpected validation result for $name: $validation_result"
        ;;
    esac
  else
    if cmp -s "$hall_script" "$rootfs_script"; then
      printf '%s: exact match\n' "$name" >> "$INIT_VALIDATION_REPORT"
    else
      diff_file="$ARTIFACTS/init-script-$name.diff"
      diff -u "$hall_script" "$rootfs_script" > "$diff_file" || true
      die "Rootfs init script $name does not match Hall's $WEB_BUILDER_REF version; see $diff_file"
    fi
  fi
done < <(find "$HALL_INIT_SRC" -maxdepth 1 -type f | sort)

find "$VERIFY_DIR/etc/init.d" -maxdepth 1 -type f -printf '%f\n' | sort > \
  "$ARTIFACTS/effective-rootfs-init-scripts.txt"

"$SCRIPT_ROOT/scripts/08-stage-nor-inputs.sh"
"$SCRIPT_ROOT/scripts/09-pack-nor-image.sh"
"$SCRIPT_ROOT/scripts/10-validate-image.sh"

IMAGE="$(cat "$ARTIFACTS/latest-image.txt")"
WEB_IMAGE="$ARTIFACTS/ms42p-postmerkos-config-status-webui-$(date -u +%Y%m%d-%H%M%S).bin"
cp -f "$IMAGE" "$WEB_IMAGE"
sha256sum "$WEB_IMAGE" | tee "$WEB_IMAGE.sha256"
printf '%s\n' "$WEB_IMAGE" > "$ARTIFACTS/latest-webui-image.txt"

log "Config-status web-enabled image completed: $WEB_IMAGE"
printf '\nAfter flashing, browse to http://<switch-ip>/\n'
printf 'configd listens on TCP 4001; runtime diagnostics are in /tmp/configd.log.\n'
printf 'Selected startup-script policy: %s\n' "$STARTUP_SCRIPT_POLICY"
printf 'Standalone clickswstatus policy: %s\n' "$CLICKSWSTATUS_POLICY"
