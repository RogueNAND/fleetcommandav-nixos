#!/usr/bin/env bash
set -euo pipefail

START_TS=$(date +%s)

# Traps ------------------------------------------------------------------------

on_error() {
  local exit_code=$?
  local line_no=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}
  echo -e "\e[31mError: command failed (exit=$exit_code) at line $line_no: $cmd\e[0m" >&2
  exit "$exit_code"
}
on_exit() {
  local end_ts
  end_ts=$(date +%s)
  local elapsed=$(( end_ts - START_TS ))
  echo -e "\e[90mDone. Elapsed: ${elapsed}s\e[0m"
}
trap on_error ERR
trap on_exit EXIT

# UI helpers -------------------------------------------------------------------

readonly COLOR1="\e[32m"
readonly COLOR_INPUT="\e[36m"
readonly ENDCOLOR="\e[0m"

msg()      { echo -e "${COLOR1}$1${ENDCOLOR}"; }
prompt()   { echo -ne "${COLOR_INPUT}$1${ENDCOLOR}"; }
die()      { echo -e "\e[31m$*\e[0m" >&2; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }
read_tty() {
  # usage: read_tty VAR "Prompt: " "default"
  local __var="$1"
  local __prompt="$2"
  local __default="${3-}"
  local __line=""

  # write prompt to the real terminal
  printf "%b" "${COLOR_INPUT}${__prompt}${ENDCOLOR}" > /dev/tty

  # read from the real terminal; don't let failure kill script
  if ! IFS= read -r __line < /dev/tty; then
    __line=""
  fi

  if [[ -z "$__line" && -n "$__default" ]]; then
    __line="$__default"
  fi

  printf -v "$__var" '%s' "$__line"
}
read_secret_tty() {
  # usage: read_secret_tty VAR "Prompt: "
  local __var="$1"
  local __prompt="$2"
  local __line=""

  printf "%s" "$__prompt" > /dev/tty
  # -s = silent; again guard against failure
  if ! read -r -s __line < /dev/tty; then
    __line=""
  fi
  echo > /dev/tty

  printf -v "$__var" '%s' "$__line"
}
run_in_tty() {
  # Run a command with stdin/stdout/stderr attached to the real terminal
  "$@" </dev/tty >/dev/tty 2>&1
}

TARGET_ETC="/etc/nixos"
REPO_URL="https://github.com/RogueNAND/fleetcommand-nixos.git"
SECRET_PATH="/var/lib/fleetcommand/secrets"
USER_PASSWORD_HASH_FILE="${SECRET_PATH}/fleetcommand.passwd"

HOSTNAME=""

# Functions --------------------------------------------------------------------

check_shell_and_root() {
  if [ -z "${BASH_VERSION:-}" ]; then
    die "Error: run with bash, not sh."
  fi

  if [[ "$EUID" -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi
}

check_dependencies() {
  # git and openssl might not be on a fresh NixOS install, so install them if needed
  local needs_install=false
  local to_install=()

  if ! have git; then
    needs_install=true
    to_install+=("nixos.git")
  fi

  if ! have openssl; then
    needs_install=true
    to_install+=("nixos.openssl")
  fi

  if [[ "$needs_install" = true ]]; then
    msg "Installing missing dependencies: ${to_install[*]}"
    nix-env -iA "${to_install[@]}"
    msg "Dependencies installed. Please rerun the bootstrap command."
    exit 0
  fi

  # Check remaining required commands
  for bin in nixos-generate-config nixos-rebuild; do
    if ! have "$bin"; then
      die "Missing required command: $bin (this should be present on NixOS)"
    fi
  done
}

determine_hostname() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    HOSTNAME="$1"
  else
    local default_hostname
    default_hostname="$(hostname)"
    read_tty HOSTNAME "Enter hostname for this box [${default_hostname}]: " "$default_hostname"
  fi

  if [[ -z "$HOSTNAME" ]]; then
    die "Error: hostname cannot be empty."
  fi

  msg "Bootstrapping host '${HOSTNAME}'..."
}

ensure_repo() {
  if [[ ! -d "$TARGET_ETC/.git" ]]; then
    local ts backup_dir
    ts="$(date +%Y%m%d-%H%M%S)"
    backup_dir="/etc/nixos-pre-bootstrap-${ts}"
    msg "Backing up existing /etc/nixos to $backup_dir..."
    mv "$TARGET_ETC" "$backup_dir"

    msg "Cloning base config repo into $TARGET_ETC..."
    git clone "$REPO_URL" "$TARGET_ETC"
  else
    msg "/etc/nixos is already a git repo. Manually run git pull to update."
    local cont
    read_tty cont "Continue? [Y/n]: " "Y"
    if [[ "$cont" =~ ^[Nn]$ ]]; then
      exit 0
    fi
    msg "Continuing without pulling. Update manually if needed."
  fi

  cd "$TARGET_ETC"
}

generate_hw_config() {
  msg "Generating hardware-configuration.nix..."
  nixos-generate-config --show-hardware-config > hardware-configuration.nix
}

prompt_user_password() {
  mkdir -p "$SECRET_PATH"
  chmod 700 "$SECRET_PATH"

  if [[ -f "$USER_PASSWORD_HASH_FILE" ]]; then
    local reuse="Y"
    read_tty reuse "Password hash exists. Reuse it? [Y/n]: " "Y"
    if [[ "$reuse" =~ ^[Yy]$ ]]; then
      return
    fi
  fi

  local pass1=""
  local pass2=""

  while true; do
    read_secret_tty pass1 "Fleetcommand user password: "
    read_secret_tty pass2 "Confirm password: "

    if [[ -z "$pass1" ]]; then
      echo "Password cannot be empty." >&2
      continue
    fi
    if [[ "$pass1" != "$pass2" ]]; then
      echo "Passwords do not match. Try again." >&2
      continue
    fi
    break
  done

  local user_password_hash=""
  user_password_hash="$(printf '%s' "$pass1" | openssl passwd -6 -stdin)"
  printf '%s\n' "$user_password_hash" > "$USER_PASSWORD_HASH_FILE"
  chmod 600 "$USER_PASSWORD_HASH_FILE"
}

ensure_host_nix() {
  if [[ ! -f host.nix ]]; then
    msg "host.nix not found, creating from template."
    sed "s/\${HOSTNAME}/${HOSTNAME}/g" host.nix.template > host.nix
  fi
}

edit_host_nix() {
  msg "Opening /etc/nixos/host.nix in an editor. Edit as needed, then save & exit."
  if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
    run_in_tty "$EDITOR" host.nix
  else
    for ed in micro nano vim vi; do
      if command -v "$ed" >/dev/null 2>&1; then
        run_in_tty "$ed" host.nix
        break
      fi
    done
  fi
}

rebuild_system() {
  msg "Running nixos-rebuild switch for ${HOSTNAME}..."
  # Clear any stale transient unit from a previous interrupted rebuild
  systemctl stop nixos-rebuild-switch-to-configuration.service 2>/dev/null || true
  systemctl reset-failed nixos-rebuild-switch-to-configuration.service 2>/dev/null || true
  nixos-rebuild switch -I nixos-config="${TARGET_ETC}/configuration.nix"
}

check_tailscale() {
  msg "Checking Tailscale authentication state..."
  local ok=0
  for _ in {1..10}; do
    if tailscale ip -4 >/dev/null 2>&1 && tailscale ip -4 | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      ok=1
      break
    fi
    sleep 2
  done

  if [[ "$ok" -eq 1 ]]; then
    msg "Tailscale appears up (IPv4: $(tailscale ip -4))."
  else
    msg "Tailscale is waiting for authentication."
    msg "Displaying QR code from service logs:"
    echo ""
    run_in_tty journalctl -u fleetcommand-tailscale-up -n 50 --no-pager
    echo ""
    msg "Scan the QR code above with your phone to authenticate."
    msg "Or check the login URL with:"
    msg "  sudo journalctl -u fleetcommand-tailscale-up -n 50"
  fi
}

main() {
  check_shell_and_root
  check_dependencies
  determine_hostname "$@"
  ensure_repo
  generate_hw_config
  prompt_user_password
  ensure_host_nix
  edit_host_nix
  rebuild_system
  check_tailscale

  msg "Bootstrap complete for ${HOSTNAME}."
}

main "$@"
