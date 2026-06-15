#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/common.sh"

BAUD="${BAUD:-115200}"
DATA_BITS="${DATA_BITS:-8}"
PARITY="${PARITY:-n}"
FLOW_CONTROL="${FLOW_CONTROL:-s}"
PORT_ARG="${1:-}"

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

install_picocom_if_needed() {
  command -v picocom >/dev/null 2>&1 && return 0
  say "picocom is required for serial monitoring."
  if ! prompt_yes_no "Install picocom now?" yes; then
    die "picocom is unavailable"
  fi
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed picocom
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y picocom
  else
    die "Unsupported package manager; install picocom manually"
  fi
}

list_serial_ports() {
  local p resolved
  for p in /dev/serial/by-id/* /dev/ttyUSB* /dev/ttyACM*; do
    [[ -e "$p" ]] || continue
    resolved=$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")
    printf '%s\t%s\n' "$p" "$resolved"
  done | awk -F '\t' '!seen[$2]++ { print $1 }'
}

port_device_group() {
  local port="$1" resolved
  resolved=$(readlink -f "$port" 2>/dev/null || printf '%s' "$port")
  stat -c '%G' "$resolved" 2>/dev/null || true
}

have_direct_port_access() {
  local port="$1" resolved
  resolved=$(readlink -f "$port" 2>/dev/null || printf '%s' "$port")
  [[ -r "$resolved" && -w "$resolved" ]]
}

add_user_to_serial_group() {
  local port="$1" group
  group=$(port_device_group "$port")
  if [[ -z "$group" || "$group" == UNKNOWN ]]; then
    say "Could not determine the group that owns $port."
    return 1
  fi

  say "Serial device $port is owned by group '$group'."
  if id -nG "$USER" | tr ' ' '\n' | grep -Fxq "$group"; then
    say "Your account already belongs to '$group', but this login session may not have refreshed its groups."
    say "Log out and back in, reboot, or start a new shell with: newgrp $group"
    return 0
  fi

  if prompt_yes_no "Add user '$USER' to group '$group' for future serial access?" yes; then
    sudo usermod -aG "$group" "$USER"
    say "Added '$USER' to '$group'. This change normally requires logging out and back in."
    say "For the current session, the console can still be opened with sudo."
    return 0
  fi
  return 1
}

choose_permission_mode() {
  local port="$1" choice group
  if have_direct_port_access "$port"; then
    printf 'direct\n'
    return 0
  fi

  group=$(port_device_group "$port")
  say "Permission denied is likely for $port."
  say "Current permissions: $(ls -l "$(readlink -f "$port" 2>/dev/null || printf '%s' "$port")" 2>/dev/null || true)"

  # A user can already be listed in the owning group while the current login
  # session still has the old supplementary-group set. This commonly happens
  # immediately after usermod -aG and is resolved by logging out/in or rebooting.
  if [[ -n "$group" && "$group" != UNKNOWN ]] &&      id -nG "$USER" | tr ' ' '\n' | grep -Fxq "$group"; then
    say "Your account is already listed in serial group '$group', but this session still cannot access the device."
    say "Log out and back in, reboot, or start a new shell with: newgrp $group"
    if prompt_yes_no "Open the serial console with sudo for this session?" yes; then
      printf 'sudo\n'
    else
      printf 'reselect\n'
    fi
    return 0
  fi

  while true; do
    cat <<'MENU'
Choose how to continue:
  1) Add this user to the serial device group
  2) Use sudo only this time
  3) Re-select a serial port
  0) Exit
MENU
    read -r -p "Selection [1]: " choice
    choice=${choice:-1}
    case "$choice" in
      1)
        if add_user_to_serial_group "$port"; then
          say "The new group membership will take effect after logging out and back in or rebooting."
          if prompt_yes_no "Open the serial console with sudo for this session?" yes; then
            printf 'sudo\n'
          else
            printf 'reselect\n'
          fi
        else
          say "The group membership was not changed."
          if prompt_yes_no "Use sudo for this session instead?" yes; then
            printf 'sudo\n'
          else
            printf 'reselect\n'
          fi
        fi
        return 0
        ;;
      2)
        printf 'sudo\n'
        return 0
        ;;
      3)
        printf 'reselect\n'
        return 0
        ;;
      0)
        printf 'exit\n'
        return 0
        ;;
      *) say "Invalid selection." ;;
    esac
  done
}

run_console() {
  local port="$1" mode="$2" log_file rc
  log_file="$LOGS/serial-$(date +%Y%m%d-%H%M%S).log"

  say "Opening $port at ${BAUD} baud, ${DATA_BITS}N1, XON/XOFF."
  say "Exit picocom with Ctrl+A, then Ctrl+X."
  say "Serial log: $log_file"

  set +e
  if [[ "$mode" == sudo ]]; then
    sudo picocom -b "$BAUD" -d "$DATA_BITS" -p "$PARITY" -f "$FLOW_CONTROL" "$port" 2>&1 | tee "$log_file"
  else
    picocom -b "$BAUD" -d "$DATA_BITS" -p "$PARITY" -f "$FLOW_CONTROL" "$port" 2>&1 | tee "$log_file"
  fi
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

select_and_monitor() {
  local ports=() choice port mode rc

  while true; do
    if [[ -n "$PORT_ARG" ]]; then
      [[ -e "$PORT_ARG" ]] || die "Serial device not found: $PORT_ARG"
      ports=("$PORT_ARG")
      choice=1
      PORT_ARG=""
    else
      mapfile -t ports < <(list_serial_ports)
      if ((${#ports[@]} == 0)); then
        say "No /dev/ttyUSB*, /dev/ttyACM*, or /dev/serial/by-id devices were found."
        prompt_yes_no "Refresh and retry?" yes || return 0
        continue
      fi

      say "Available serial interfaces:"
      local i
      for i in "${!ports[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${ports[$i]}"
      done
      printf '  0) Exit\n'
      read -r -p "Select a serial interface: " choice
      [[ "$choice" == 0 ]] && return 0
      [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ports[@]} )) || {
        say "Invalid selection."
        continue
      }
    fi

    port="${ports[$((choice-1))]}"
    mode=$(choose_permission_mode "$port")
    case "$mode" in
      exit) return 0 ;;
      reselect) continue ;;
      direct|sudo) ;;
      *) die "Unexpected permission mode: $mode" ;;
    esac

    if run_console "$port" "$mode"; then
      return 0
    fi
    rc=$?
    say "Serial connection failed with exit code $rc."
    prompt_yes_no "Refresh the port list and retry?" yes || return 0
  done
}

install_picocom_if_needed
mkdir -p "$LOGS"
select_and_monitor
