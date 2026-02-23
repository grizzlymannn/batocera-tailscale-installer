#!/bin/bash
set -euo pipefail

VERSION="dev"

INSTALL_DIR="/userdata/tailscale"
SERVICE_DIR="/userdata/system/services"
SERVICE_NAME="tailscale"

TMPDIR="$(mktemp -d)"
cleanup() {
  [[ -d $TMPDIR ]] && rm -rf "$TMPDIR"
  unset GNUPGHOME
}
trap cleanup EXIT

FORCE=0
AUTH_KEY=""
NONINTERACTIVE=0
TRACK="${TRACK:-stable}" # stable|unstable
PKGS="https://pkgs.tailscale.com/${TRACK}/"
GPG_KEY_FPR="2596A99E13C79D1737E11F0B5E304C4E0A6B90D1" # Tailscale release key
CONFIG_FILE="$INSTALL_DIR/config.conf"
CONFIG_TEMPLATE="$INSTALL_DIR/config.conf.template"
TMP_INSTALL_DIR="$INSTALL_DIR/.new"
INSTALLED_VERSION_FILE="$INSTALL_DIR/version"
CURRENT_VERSION=""

# Create temporary GPG environment so we don’t pollute system
GNUPGHOME="$TMPDIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
export GNUPGHOME

# ---------------------------
# CLI parsing
# ---------------------------
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --auth-key=*) AUTH_KEY="${arg#*=}" ;;
    --non-interactive) NONINTERACTIVE=1 ;;
  esac
done

AUTH_KEY="${AUTH_KEY:-${TS_AUTHKEY:-}}"

# ---------------------------
# Helper functions
# ---------------------------
require_root() { [[ $EUID -eq 0 ]] || {
  echo "ERROR: Must be run as root" >&2
  exit 1
}; }

check_deps() {
  local DEPS=(curl gpg sha256sum tar install modprobe pkill pgrep)
  local missing=()
  for cmd in "${DEPS[@]}"; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -eq 0 ]] || {
    echo "ERROR: Missing dependencies: ${missing[*]}" >&2
    exit 1
  }
}

detect_arch() {
  local arch_raw
  arch_raw="$(uname -m)"
  case "$arch_raw" in
    x86_64 | amd64) arch="amd64" ;;
    i*86) arch="386" ;;
    aarch64 | arm64) arch="arm64" ;;
    armv7* | armv6* | armf) arch="arm" ;;
    riscv64) arch="riscv64" ;;
    *)
      echo "ERROR: Unsupported architecture $arch_raw" >&2
      exit 1
      ;;
  esac
  echo "Detected architecture: $arch ($arch_raw)"
}

stop_existing() {
  echo "Stopping existing Tailscale..."

  # Stop via Batocera service manager (if present)
  if command -v batocera-services > /dev/null 2>&1; then
    batocera-services stop tailscale > /dev/null 2>&1 || true
    batocera-services disable tailscale > /dev/null 2>&1 || true
  fi

  # Stop any tailscale binaries previously started outside the service
  [[ -x "$INSTALL_DIR/tailscale" ]] && "$INSTALL_DIR/tailscale" down > /dev/null 2>&1 || true
  # Kill lingering daemons (best-effort)
  pkill -x tailscaled > /dev/null 2>&1 || true
  pkill -x tailscale > /dev/null 2>&1 || true

  # Wait briefly for shutdown to complete
  for _ in 1 2 3 4 5; do
    pgrep -x tailscaled > /dev/null 2>&1 || break
    sleep 0.2
  done

  if pgrep -x tailscaled > /dev/null 2>&1; then
    echo "tailscaled is still running; forcing stop..." >&2
    pkill -9 -x tailscaled > /dev/null 2>&1 || true
  fi
}

check_tun() {
  [[ -c /dev/net/tun ]] || (modprobe tun > /dev/null 2>&1 || true)
  [[ -c /dev/net/tun ]] || {
    echo "ERROR: TUN device unavailable" >&2
    exit 1
  }
}

backup_config() {
  local file="$1"
  [[ -f $file ]] && cp "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
}

update_config_key() {
  local key="$1" value="$2" file="$3"
  local escaped_value
  escaped_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')
  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${escaped_value}|" "$file"
  else
    printf "%s=%s\n" "$key" "$escaped_value" >> "$file"
  fi
}

valid_cidr() {
  local cidr="$1"
  [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  local ip mask
  ip="${cidr%/*}"
  mask="${cidr#*/}"
  ((mask >= 0 && mask <= 32)) || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    ((o >= 0 && o <= 255)) || return 1
  done
  return 0
}

install_files() {
  echo "Staging binaries, scripts, and service for install..."

  # Clean and create temp staging directory
  rm -rf "$TMP_INSTALL_DIR"
  mkdir -p "$TMP_INSTALL_DIR"

  # ---- Stage binaries ----
  install -m 0755 "$EXTRACTED_DIR/tailscale" "$TMP_INSTALL_DIR/tailscale"
  install -m 0755 "$EXTRACTED_DIR/tailscaled" "$TMP_INSTALL_DIR/tailscaled"

  # ---- Stage scripts ----
  install -m 0755 monitor.sh "$TMP_INSTALL_DIR/monitor.sh"
  install -m 0755 watchdog.sh "$TMP_INSTALL_DIR/watchdog.sh"

  # ---- Move everything atomically ----
  mkdir -p "$INSTALL_DIR"
  mv "$TMP_INSTALL_DIR"/* "$INSTALL_DIR/"

  rm -rf "$TMP_INSTALL_DIR"

  echo "$TS_VER" > "$INSTALL_DIR/version"
  echo "Binaries and scripts installed to $INSTALL_DIR."

  # ---- Install service ----
  echo "Installing service..."
  mkdir -p "$SERVICE_DIR"
  install -m 0755 "services/$SERVICE_NAME" "$SERVICE_DIR/$SERVICE_NAME"
  echo "Service installed to $SERVICE_DIR/$SERVICE_NAME"

  # ---- Copy config template if missing ----
  if [[ ! -f $CONFIG_FILE && -f $CONFIG_TEMPLATE ]]; then
    cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
    echo "Default configuration template copied to $CONFIG_FILE"
  fi
}

perform_auth_login() {
  # Skip if no auth key provided
  [[ -z $AUTH_KEY ]] && return

  echo
  echo "Attempting Tailscale authentication with provided auth key..."

  # Start tailscaled if not running
  if [[ -x "$INSTALL_DIR/tailscaled" ]] && ! pgrep -x tailscaled > /dev/null 2>&1; then
    "$INSTALL_DIR/tailscaled" -state "$INSTALL_DIR/state" > /dev/null 2>&1 &
    sleep 2
  fi

  # Attempt automatic login
  if "$INSTALL_DIR/tailscale" up --auth-key="$AUTH_KEY" > /dev/null 2>&1; then
    echo "Authentication successful."
  else
    echo "ERROR: Authentication with provided key failed."
    echo
    echo "You can manually authenticate by running:"
    echo "    $INSTALL_DIR/tailscale up"
    echo "Follow the URL printed by Tailscale to complete authentication."
    echo
    # Optional: in non-interactive mode, just return
    if [[ $NONINTERACTIVE -eq 1 ]]; then
      return
    fi

    # In interactive mode, offer to launch manual login automatically
    read -rp "Would you like to attempt manual login now? (y/N): " RESP
    if [[ $RESP =~ ^[Yy]$ ]]; then
      "$INSTALL_DIR/tailscale" up || echo "Manual login failed. You can retry later."
    else
      echo "Skipping manual login. You can run '$INSTALL_DIR/tailscale up' later."
    fi
  fi
}

run_config_wizard() {
  echo
  echo "========== Tailscale Configuration =========="
  echo

  # Helper functions
  prompt_yes_no() {
    local prompt="$1"
    local default="$2" # 1 = yes, 0 = no
    local reply

    if [[ $default -eq 1 ]]; then
      read -rp "$prompt (Y/n): " reply
      [[ $reply =~ ^[Nn]$ ]] && echo 0 || echo 1
    else
      read -rp "$prompt (y/N): " reply
      [[ $reply =~ ^[Yy]$ ]] && echo 1 || echo 0
    fi
  }

  prompt_optional_string() {
    local prompt="$1"
    local reply
    read -rp "$prompt: " reply
    echo "$reply"
  }

  # Auto-detect local subnet
  DEFAULT_IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
  DEFAULT_CIDR="$(ip -o -4 route show dev "$DEFAULT_IFACE" scope link proto kernel 2> /dev/null | awk '{print $1; exit}')"

  echo "Detected interface: ${DEFAULT_IFACE:-unknown}"
  echo "Detected subnet:    ${DEFAULT_CIDR:-unknown}"
  echo

  # Basic Options
  echo "----- Basic Options -----"
  echo

  # Advertise subnet
  if [[ -n $DEFAULT_CIDR && "$(prompt_yes_no "Advertise this subnet to your tailnet?" 0)" -eq 1 ]]; then
    if valid_cidr "$DEFAULT_CIDR"; then
      ADVERTISE_ROUTES="\"$DEFAULT_CIDR\""
      SNAT_SUBNET_ROUTES="$(prompt_yes_no "Enable SNAT for subnet routes?" 1)"
    else
      echo "Invalid detected CIDR. Skipping advertisement."
      ADVERTISE_ROUTES=""
    fi
  else
    ADVERTISE_ROUTES=""
  fi

  # Offer exit node
  ADVERTISE_EXIT_NODE="$(prompt_yes_no "Offer this device as an exit node?" 0)"

  # Accept routes
  ACCEPT_ROUTES="$(prompt_yes_no "Accept routes from other nodes?" 0)"

  # Use exit node
  if [[ "$(prompt_yes_no "Use an exit node for internet traffic?" 0)" -eq 1 ]]; then
    EXIT_NODE_RAW="$(prompt_optional_string "Enter exit node name or IP")"
    if [[ -n $EXIT_NODE_RAW ]]; then
      EXIT_NODE="\"$EXIT_NODE_RAW\""
    fi
  else
    EXIT_NODE=""
  fi

  # Advanced Options
  echo
  if [[ "$(prompt_yes_no "Configure advanced options?" 0)" -eq 1 ]]; then
    echo
    echo "----- Advanced Options -----"
    echo

    EXIT_NODE_ALLOW_LAN_ACCESS="$(prompt_yes_no "Allow LAN access when using exit node?" 0)"
    ACCEPT_DNS="$(prompt_yes_no "Accept DNS settings from tailnet?" 1)"
    SHIELDS_UP="$(prompt_yes_no "Enable shields-up (block incoming connections)?" 0)"
    STATEFUL_FILTERING="$(prompt_yes_no "Enable stateful filtering?" 0)"

    HOST_RAW="$(prompt_optional_string "Set custom hostname (leave blank to skip)")"
    [[ -n $HOST_RAW ]] && HOSTNAME="\"$HOST_RAW\""

    read -rp "Netfilter mode (on/off/nodivert, leave blank for default): " NF_RAW
    if [[ $NF_RAW =~ ^(on|off|nodivert)$ ]]; then
      NETFILTER_MODE="\"$NF_RAW\""
    fi
  fi

  # Save Configuration
  echo
  echo "Updating configuration..."

  [[ -f $CONFIG_FILE ]] && backup_config "$CONFIG_FILE"

  update_config_key "ADVERTISE_ROUTES" "${ADVERTISE_ROUTES:-}" "$CONFIG_FILE"
  update_config_key "SNAT_SUBNET_ROUTES" "${SNAT_SUBNET_ROUTES:-0}" "$CONFIG_FILE"
  update_config_key "ADVERTISE_EXIT_NODE" "${ADVERTISE_EXIT_NODE:-0}" "$CONFIG_FILE"
  update_config_key "ACCEPT_ROUTES" "${ACCEPT_ROUTES:-0}" "$CONFIG_FILE"
  update_config_key "EXIT_NODE" "${EXIT_NODE:-}" "$CONFIG_FILE"
  update_config_key "EXIT_NODE_ALLOW_LAN_ACCESS" "${EXIT_NODE_ALLOW_LAN_ACCESS:-0}" "$CONFIG_FILE"
  update_config_key "ACCEPT_DNS" "${ACCEPT_DNS:-1}" "$CONFIG_FILE"
  update_config_key "SHIELDS_UP" "${SHIELDS_UP:-0}" "$CONFIG_FILE"
  update_config_key "STATEFUL_FILTERING" "${STATEFUL_FILTERING:-0}" "$CONFIG_FILE"
  update_config_key "HOSTNAME" "${HOSTNAME:-}" "$CONFIG_FILE"
  update_config_key "NETFILTER_MODE" "${NETFILTER_MODE:-}" "$CONFIG_FILE"

  echo "Configuration updated successfully."
  echo
}

# ---------------------------
# Main installer
# ---------------------------
main() {
  require_root
  check_deps
  detect_arch
  stop_existing
  check_tun

  mkdir -p "$INSTALL_DIR"

  # Get current installed version
  [[ -f $INSTALLED_VERSION_FILE ]] && CURRENT_VERSION="$(< "$INSTALLED_VERSION_FILE")"

  # Find latest Tailscale version
  cd "$TMPDIR"
  TS_VER="$(
    curl -fsSL "$PKGS" |
      grep -oE "tailscale_[0-9]+\.[0-9]+\.[0-9]+_${arch}\.tgz" |
      sed -E "s/^tailscale_([0-9]+\.[0-9]+\.[0-9]+)_${arch}\.tgz/\1/" |
      sort -V | tail -n1
  )"
  [[ -n $TS_VER ]] || {
    echo "ERROR: Could not detect latest Tailscale version" >&2
    exit 1
  }

  if [[ $FORCE -eq 0 && $CURRENT_VERSION == "$TS_VER" ]]; then
    echo "Tailscale $TS_VER already installed. Skipping installation."
    return
  fi

  if [[ $FORCE -eq 1 ]]; then
    echo "Force flag detected — reinstalling Tailscale $TS_VER"
  elif [[ -n $CURRENT_VERSION ]]; then
    echo "Upgrading from $CURRENT_VERSION → $TS_VER"
  else
    echo "Installing Tailscale $TS_VER..."
  fi

  TGZ="tailscale_${TS_VER}_${arch}.tgz"
  URL="${PKGS}${TGZ}"
  EXPECTED_DIR="tailscale_${TS_VER}_${arch}"

  # Download and verify
  echo "Downloading SHA256SUMS and signature..."
  curl -fLO "${PKGS}SHA256SUMS"
  curl -fLO "${PKGS}SHA256SUMS.sig"
  echo "Importing Tailscale GPG key..."
  curl -fsSL https://pkgs.tailscale.com/stable/tailscale.asc | gpg --import > /dev/null 2>&1

  # Verify fingerprint matches expected
  IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '/^fpr:/ {print $10}' | head -n1)"

  if [[ $IMPORTED_FPR != "$GPG_KEY_FPR" ]]; then
    echo "ERROR: GPG fingerprint mismatch!" >&2
    echo "Expected: $GPG_KEY_FPR" >&2
    echo "Got:      $IMPORTED_FPR" >&2
    exit 1
  fi

  echo "Verifying signature..."
  gpg --verify SHA256SUMS.sig SHA256SUMS > /dev/null 2>&1 || {
    echo "ERROR: Signature invalid" >&2
    exit 1
  }

  echo "Downloading Tailscale archive..."
  curl -fLO --connect-timeout 15 --max-time 600 "$URL"
  grep " $TGZ\$" SHA256SUMS | sha256sum -c - > /dev/null 2>&1 || {
    echo "ERROR: Checksum verification failed!" >&2
    exit 1
  }

  echo "Extracting..."
  tar --no-same-owner --no-same-permissions -xzf "$TGZ"
  EXTRACTED_DIR="$EXPECTED_DIR"

  [[ -x "$EXTRACTED_DIR/tailscale" && -x "$EXTRACTED_DIR/tailscaled" ]] || {
    echo "ERROR: binaries missing" >&2
    exit 1
  }

  install_files

  # Auth login
  if [[ -z $AUTH_KEY && $NONINTERACTIVE -eq 0 ]]; then
    read -rsp "Enter Tailscale auth key (blank to skip): " AUTH_KEY
    echo
  fi
  perform_auth_login

  # Configuration wizard
  if [[ $NONINTERACTIVE -eq 0 && -f $CONFIG_FILE ]]; then
    read -rp "Run configuration wizard now? (y/N): " CONF
    [[ $CONF =~ ^[Yy]$ ]] && run_config_wizard
  fi

  echo "Tailscale $TS_VER installed successfully!"
}

main "$@"
