#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
usage: fwupdate-publish.sh FIRMWARE.bin DESTINATION [VERSION] [DESCRIPTION]

Copies a firmware file into an HTTP(S) publication directory, creates a strict
basename-matching .sha256 sidecar, and atomically updates index.tsv.
USAGE
}

[[ $# -ge 2 ]] || { usage >&2; exit 2; }
firmware=$(realpath "$1")
dest=$2
version=${3:-}
description=${4:-postmerkOS MS42/MS42P firmware}
[[ -f "$firmware" ]] || { echo "firmware not found: $firmware" >&2; exit 1; }
name=$(basename "$firmware")
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "unsafe filename: $name" >&2; exit 1; }
[[ -n "$version" ]] || {
  version=${name#ms42p-postmerkos-}
  version=${version%.bin}
}
[[ "$version" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "unsafe version: $version" >&2; exit 1; }
[[ "$description" != *'|'* && "$description" != *$'\n'* && "$description" != *$'\r'* ]] || {
  echo "description may not contain pipes or newlines" >&2; exit 1;
}
size=$(stat -c %s "$firmware")
[[ $size -eq 16777216 ]] || { echo "expected a 16 MiB firmware image, got $size bytes" >&2; exit 1; }
mkdir -p "$dest"
install -m 0644 "$firmware" "$dest/$name"
(
  cd "$dest"
  sha256sum "$name" > "$name.sha256"
)
index="$dest/index.tsv"
tmp="$dest/.index.tsv.$$"
{
  printf '# version|target|firmware filename|byte size|description\n'
  printf '%s|ms42p|%s|%s|%s\n' "$version" "$name" "$size" "$description"
  if [[ -f "$index" ]]; then
    awk -F'|' -v v="$version" '
      /^#/ { next }
      !($1 == v && $2 == "ms42p") { print }
    ' "$index"
  fi
} > "$tmp"
mv -f "$tmp" "$index"
printf 'Published %s\n' "$dest/$name"
printf 'Sidecar:  %s\n' "$dest/$name.sha256"
printf 'Index:    %s\n' "$index"
