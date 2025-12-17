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
REPO_URL="https://github.com/roguenand/fleetcommandav-nixos.git"
SECRET_PATH="/run/secrets"
AUTH_FILE="${SECRET_PATH}/tailscale-authkey"

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
  for bin in git nixos-generate-config nixos-rebuild; do
    if ! have "$bin"; then
      die "Missing required command: $bin"
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
    msg "/etc/nixos is already a git repo."
    local pull
    read_tty pull "Pull latest changes from origin? [y/N]: " "N"
    if [[ "$pull" =~ ^[Yy]$ ]]; then
      msg "Pulling latest changes..."
      (cd "$TARGET_ETC" && git pull --ff-only || true)
    fi
  fi

  cd "$TARGET_ETC"
}

generate_hw_config() {
  msg "Generating hardware-configuration.nix..."
  nixos-generate-config --show-hardware-config > hardware-configuration.nix
}

ensure_host_nix() {
  if [[ ! -f host.nix ]]; then
    msg "host.nix not found, creating a new one."
    cat > host.nix <<EOF
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  networking.hostName = "${HOSTNAME}";
  time.timeZone = "America/New_York";
  zramSwap.memoryPercent = 50;

  services.tailscale = {
    # NOTE: this must be a literal path; the auth key is written by bootstrap.sh
    authKeyFile = "/run/secrets/tailscale-authkey";
    useRoutingFeatures = "client";  # Exit node only by default

    extraUpFlags = [
      # "--login-server=https://headscale.example.com"
      "--ssh"
      "--advertise-exit-node"
      "--hostname=\${config.networking.hostName}"
    ];
  };

  system.stateVersion = "25.11";
}
EOF
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

setup_tailscale_auth() {
  mkdir -p "$SECRET_PATH"
  chmod 700 "$SECRET_PATH"

  if [[ ! -f "$AUTH_FILE" ]]; then
    echo
    msg "Tailscale/Headscale auth key not found for this host."
    echo "(You can generate a one-time key from the admin panel.)"
    local AUTH_KEY=""
    read_secret_tty AUTH_KEY "Auth key: "

    if [[ -z "$AUTH_KEY" ]]; then
      echo "No auth key entered; Tailscale will not auto-connect." >&2
    else
      printf '%s\n' "$AUTH_KEY" > "$AUTH_FILE"
      chmod 600 "$AUTH_FILE"
      msg "Auth key stored at $AUTH_FILE for one-time use."
    fi
  fi
}

rebuild_system() {
  msg "Running nixos-rebuild switch for ${HOSTNAME}..."
  nixos-rebuild switch -I nixos-config="${TARGET_ETC}/configuration.nix"
}

check_tailscale() {
  msg "Checking Tailscale authentication state..."
  local ok=0
  for _ in {1..10}; do
    if tailscale status 2>&1 | grep -q "Logged in as"; then
      ok=1
      break
    fi
    sleep 2
  done

  if [[ "$ok" -eq 1 ]]; then
    msg "Tailscale authenticated successfully."
  else
    msg "Tailscale does not appear to be logged in (or status not yet updated)."
    msg "You can re-run manually with:"
    msg "  sudo tailscale up"
  fi
}

main() {
  check_shell_and_root
  check_dependencies
  determine_hostname "$@"
  ensure_repo
  generate_hw_config
  ensure_host_nix
  edit_host_nix
  setup_tailscale_auth
  rebuild_system
  check_tailscale

  msg "Bootstrap complete for ${HOSTNAME}."
}

main "$@"
