#!/usr/bin/env bash
source "$(dirname "$0")/common.sh"
need git

clone_pin() {
  local url="$1" dir="$2" commit="$3"
  if [[ ! -d "$dir/.git" ]]; then git clone "$url" "$dir"; fi
  git -C "$dir" fetch --all --tags
  if [[ "${ALLOW_DIRTY:-0}" != 1 ]] && [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    die "$dir has local changes. Commit/stash them or use ALLOW_DIRTY=1."
  fi
  git -C "$dir" checkout --detach "$commit"
}

clone_ref() {
  local url="$1" dir="$2" ref="$3"
  if [[ ! -d "$dir/.git" ]]; then git clone "$url" "$dir"; fi
  git -C "$dir" fetch origin "$ref" --tags
  if [[ "${ALLOW_DIRTY:-0}" != 1 ]] && [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    die "$dir has local changes. Commit/stash them or use ALLOW_DIRTY=1."
  fi
  git -C "$dir" checkout --detach FETCH_HEAD
}

log "Fetching pinned kernel/toolchain and Hall builder revisions"
clone_pin "$SWITCH_REPO_URL" "$SWITCH_DIR" "$SWITCH_COMMIT"
clone_pin "$BUILDER_REPO_URL" "$BUILDER_DIR" "$BUILDER_COMMIT"

log "Fetching Hal Martin's Buildroot integration from $HAL_BUILDER_REF"
clone_ref "$HAL_BUILDER_REPO_URL" "$HAL_BUILDER_DIR" "$HAL_BUILDER_REF"
HAL_BUILDER_COMMIT="$(git -C "$HAL_BUILDER_DIR" rev-parse HEAD)"

log "Fetching Hall's web-management Buildroot integration from $CONFIG_STATUS_BUILDER_REF"
clone_ref "$CONFIG_STATUS_BUILDER_REPO_URL" "$CONFIG_STATUS_BUILDER_DIR" "$CONFIG_STATUS_BUILDER_REF"
CONFIG_STATUS_BUILDER_COMMIT="$(git -C "$CONFIG_STATUS_BUILDER_DIR" rev-parse HEAD)"

cat > "$ARTIFACTS/source-revisions.txt" <<EOT
switch-11-22-ms220 $SWITCH_COMMIT
hall/meraki-builder pinned base $BUILDER_COMMIT
hall/meraki-builder $CONFIG_STATUS_BUILDER_COMMIT ($CONFIG_STATUS_BUILDER_REF)
halmartin/meraki-builder $HAL_BUILDER_COMMIT ($HAL_BUILDER_REF)
EOT
log "Source revisions written to $ARTIFACTS/source-revisions.txt"
