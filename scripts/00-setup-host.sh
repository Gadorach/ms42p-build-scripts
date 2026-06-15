#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="${PROJECT_ROOT:-$HOME/meraki-ms42p-build}"
CONTAINER_NAME="${CONTAINER_NAME:-meraki-build}"
IMAGE="${IMAGE:-ubuntu:22.04}"

if command -v pacman >/dev/null 2>&1; then
  sudo pacman -Syu --needed --noconfirm git distrobox podman
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y git distrobox podman
else
  echo "Install git, distrobox and podman, then rerun." >&2
  exit 1
fi

mkdir -p "$PROJECT_ROOT"/{inputs,sources,build,extracted,staging,artifacts,logs,scripts,support}

if ! distrobox list 2>/dev/null | grep -qE "(^|[[:space:]])${CONTAINER_NAME}([[:space:]]|$)"; then
  distrobox create --name "$CONTAINER_NAME" --image "$IMAGE" --yes
fi

cat <<MSG
Host setup complete.
Copy the supplied script bundle contents into:
  $PROJECT_ROOT
Place donor files in:
  $PROJECT_ROOT/inputs

Enter the build environment with:
  distrobox enter $CONTAINER_NAME

The scripts are Bash scripts. They work regardless of whether your interactive shell is fish or Bash; invoke them as ./scripts/<name>.sh or bash ./scripts/<name>.sh.
MSG
