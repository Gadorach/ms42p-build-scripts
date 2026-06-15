#!/bin/sh
set -eu
: "${TARGET_DIR:?TARGET_DIR is required}"
mkdir -p "$TARGET_DIR/overlay" "$TARGET_DIR/click" "$TARGET_DIR/etc"
if [ -L "$TARGET_DIR/etc/dropbear" ]; then rm -f "$TARGET_DIR/etc/dropbear"; fi
IMAGE_DATE="${SOURCE_DATE_EPOCH:+$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d 2>/dev/null || true)}"
[ -n "$IMAGE_DATE" ] || IMAGE_DATE=$(date -u +%Y%m%d)
cat > "$TARGET_DIR/etc/lsb-release" <<EOT
DISTRIB_ID="postmerkOS"
DISTRIB_RELEASE="$IMAGE_DATE"
DISTRIB_DESCRIPTION="postmerkOS mipsel"
EOT
if [ -f "$TARGET_DIR/etc/shadow" ] && [ -f "$TARGET_DIR/etc/init.d/S14passwd" ]; then
  salt=$(awk -F'\$' '/^root:/ {print $3; exit}' "$TARGET_DIR/etc/shadow" | sed 's|/|\\/|g')
  if [ -n "$salt" ]; then sed -i "s/__SALT__/$salt/g" "$TARGET_DIR/etc/init.d/S14passwd"; fi
fi
