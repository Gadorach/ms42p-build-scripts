#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

PROGRAMMER="${PROGRAMMER:-ch341a_spi}"
CHIP="${CHIP:-MX25L12805D}"
BACKUP_READS="${BACKUP_READS:-3}"
EXPECTED_SIZE=$((16 * 1024 * 1024))
IMAGE="${1:-}"

say() { printf '\n%s\n' "$*"; }
prompt_yes_no() {
  local prompt="$1" default="${2:-yes}" answer
  if [[ "$default" == yes ]]; then
    read -r -p "$prompt [Y/n] " answer || true
    [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
  else
    read -r -p "$prompt [y/N] " answer || true
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
  fi
}
pause_confirm() {
  local text="$1"
  printf '\n%s\n' "$text"
  read -r -p "Press Enter when ready, or Ctrl+C to abort... " _
}
install_host_tools_if_needed() {
  local missing=()
  command -v flashrom >/dev/null 2>&1 || missing+=(flashrom)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  command -v cmp >/dev/null 2>&1 || missing+=(diffutils)
  ((${#missing[@]} == 0)) && return
  say "Missing required host tools: ${missing[*]}"
  if ! prompt_yes_no "Install the missing tools now?" yes; then
    die "Required host tools are unavailable"
  fi
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed flashrom picocom coreutils diffutils
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y flashrom picocom coreutils diffutils
  else
    die "Unsupported host package manager; install flashrom, picocom, coreutils and diffutils manually"
  fi
}
select_image() {
  if [[ -z "$IMAGE" && -f "$ARTIFACTS/latest-image.txt" ]]; then
    IMAGE=$(<"$ARTIFACTS/latest-image.txt")
  fi
  [[ -n "$IMAGE" && -f "$IMAGE" ]] || die "Pass a firmware image path or run stages 09 and 10 first"
  IMAGE=$(readlink -f "$IMAGE")
  local size
  size=$(stat -c %s "$IMAGE")
  [[ "$size" -eq "$EXPECTED_SIZE" ]] || die "Firmware must be exactly $EXPECTED_SIZE bytes; got $size"
  say "Firmware image: $IMAGE"
  sha256sum "$IMAGE"
}
flashrom_cmd() {
  sudo flashrom -p "$PROGRAMMER" -c "$CHIP" "$@"
}
backup_once_set() {
  local dir="$1" i file reference
  rm -rf "$dir"
  mkdir -p "$dir"
  for ((i=1; i<=BACKUP_READS; i++)); do
    file="$dir/original-nor-read-$i.bin"
    say "Reading original NOR: pass $i of $BACKUP_READS"
    flashrom_cmd -r "$file"
    [[ $(stat -c %s "$file") -eq "$EXPECTED_SIZE" ]] || {
      printf 'Read %d has the wrong size.\n' "$i" >&2
      return 1
    }
    sha256sum "$file"
  done
  reference="$dir/original-nor-read-1.bin"
  for ((i=2; i<=BACKUP_READS; i++)); do
    cmp -s "$reference" "$dir/original-nor-read-$i.bin" || {
      printf 'Backup reads do not match byte-for-byte.\n' >&2
      return 1
    }
  done
  cp -f "$reference" "$dir/original-nor-confirmed.bin"
  sha256sum "$dir"/*.bin > "$dir/SHA256SUMS"
  say "All $BACKUP_READS reads match perfectly."
  say "Confirmed backup: $dir/original-nor-confirmed.bin"
}
perform_backup() {
  local stamp dir attempt=0
  stamp=$(date +%Y%m%d-%H%M%S)
  dir="$ARTIFACTS/backups/$stamp"
  while true; do
    attempt=$((attempt+1))
    say "Backup attempt $attempt"
    if backup_once_set "$dir"; then
      return 0
    fi
    say "Backup attempt failed or produced mismatched reads. Flashing is blocked."
    if ! prompt_yes_no "Retry the complete backup read set?" yes; then
      die "No verified original NOR backup was produced; refusing to flash"
    fi
  done
}
perform_flash() {
  local attempt=0 verify_tmp
  while true; do
    attempt=$((attempt+1))
    say "Flash attempt $attempt"
    if flashrom_cmd -V -w "$IMAGE"; then
      # flashrom normally verifies after writing. Perform one explicit readback
      # as an additional full-image comparison.
      verify_tmp=$(mktemp "$ARTIFACTS/.flash-verify.XXXXXX.bin")
      if flashrom_cmd -r "$verify_tmp" && cmp -s "$IMAGE" "$verify_tmp"; then
        rm -f "$verify_tmp"
        say "Flash and explicit readback verification succeeded."
        return 0
      fi
      rm -f "$verify_tmp"
      say "Write returned success, but explicit readback did not match."
    else
      say "flashrom reported a write failure."
    fi
    if ! prompt_yes_no "Retry flashing?" yes; then
      die "Firmware was not successfully verified"
    fi
  done
}
serial_monitor() {
  local utility="$(dirname "$0")/12-serial-console.sh"
  [[ -x "$utility" ]] || die "Serial utility is missing or not executable: $utility"
  "$utility"
}

install_host_tools_if_needed
select_image

say "FLASHING SAFETY REQUIREMENTS"
say "1. The switch must be fully powered OFF and unplugged before any flashrom read or write."
say "2. Connect the SPI programmer only while the switch is unpowered."
say "3. Do not power the switch while the SPI programmer is electrically connected."
pause_confirm "Confirm that the switch is unplugged and the programmer is connected correctly."

if prompt_yes_no "Back up the original NOR before flashing?" yes; then
  perform_backup
else
  say "Backup skipped by explicit user choice."
  prompt_yes_no "Continue without a verified backup?" no || die "Aborted before flashing"
fi

pause_confirm "The switch must still be powered OFF. Leave the SPI programmer connected for flashing."
perform_flash

say "IMPORTANT: DO NOT POWER ON THE SWITCH YET."
say "Disconnect the SPI programmer and chip clip/wires from the switch first."
pause_confirm "After the programmer is fully disconnected, reconnect UART if desired, then power on the switch."

if prompt_yes_no "Open a serial console now?" yes; then
  serial_monitor
fi
