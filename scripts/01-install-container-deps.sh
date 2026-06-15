#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need sudo
log "Installing Ubuntu 22.04 build dependencies"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential git ca-certificates curl wget rsync unzip zip file bc bzip2 xz-utils \
  python3 python3-setuptools python3-distutils perl ruby gawk gettext flex bison patch diffutils \
  libgmp-dev libmpfr-dev libmpc-dev libexpat1-dev zlib1g-dev libncurses5-dev libncursesw5-dev \
  pkg-config libtool autoconf automake autotools-dev m4 texinfo help2man \
  u-boot-tools device-tree-compiler squashfs-tools mtd-utils xxd cpio jq

if [[ -x /usr/bin/aclocal-1.16 ]]; then sudo ln -sf /usr/bin/aclocal-1.16 /usr/bin/aclocal-1.14; fi
if [[ -x /usr/bin/automake-1.16 ]]; then sudo ln -sf /usr/bin/automake-1.16 /usr/bin/automake-1.14; fi
log "Dependency installation complete"
