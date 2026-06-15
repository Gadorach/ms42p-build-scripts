#!/usr/bin/env bash
set -Eeuo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
for s in 01-install-container-deps.sh 02-fetch-sources.sh 03-build-openwrt-toolchain.sh 04-build-compressed-kernel.sh 05-extract-donor.sh 06-prepare-buildroot.sh 07-build-rootfs.sh 08-stage-nor-inputs.sh 09-pack-nor-image.sh 10-validate-image.sh; do
  echo "===== $s ====="
  "$D/$s"
done
