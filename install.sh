#!/bin/bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

DEPS=(curl gpg sha256sum tar install modprobe pkill pgrep)
MISSING=()

for CMD in "${DEPS[@]}"; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        MISSING+=("$CMD")
    fi
done

if [[ ${#MISSING[@]} -ne 0 ]]; then
    echo "ERROR: Missing required dependencies:" >&2
    for m in "${MISSING[@]}"; do
        echo "  - $m" >&2
    done
    echo "Please install them before running this script." >&2
    exit 1
fi

echo "All required dependencies are present."

# Unique temp dir under /userdata
TMPDIR="$(mktemp -d /userdata/tmp.tailscale.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

FORCE=0
AUTH_KEY=""
NONINTERACTIVE=0

for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    --auth-key=*)
      AUTH_KEY="${arg#*=}"
      ;;
    --non-interactive)
      NONINTERACTIVE=1
      ;;
  esac
done

AUTH_KEY="${AUTH_KEY:-${TS_AUTHKEY:-}}"
TRACK="${TRACK:-stable}"  # stable|unstable
PKGS="https://pkgs.tailscale.com/${TRACK}/"
GPG_KEY_FPR="2596A99E13C79D1737E11F0B5E304C4E0A6B90D1"  # Tailscales GPG key for download checksum.
INSTALL_DIR="/userdata/tailscale"
CONFIG_FILE="$INSTALL_DIR/config.conf"
CONFIG_TEMPLATE="$INSTALL_DIR/config.conf.template"
TMP_INSTALL_DIR="$INSTALL_DIR/.new"
INSTALLED_VERSION_FILE="$INSTALL_DIR/version"
CURRENT_VERSION=""

mkdir -p "$INSTALL_DIR"

if [[ -f "$INSTALLED_VERSION_FILE" ]]; then
  CURRENT_VERSION="$(cat "$INSTALLED_VERSION_FILE" 2>/dev/null || true)"
fi

# Create temporary GPG environment so we don’t pollute system
GNUPGHOME="$TMPDIR/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
export GNUPGHOME

# Detect Tailscale tarball arch (matches pkgs.tailscale.com naming)
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) arch="amd64";;
  i386|i486|i586|i686) arch="386";;
  aarch64|arm64) arch="arm64";;
  armv7l|armv7|armhf) arch="arm";;
  armv6l|armv6) arch="arm";;
  riscv64) arch="riscv64";;
  *) echo "ERROR: Unsupported architecture"; exit 1;;
esac

echo "Arch detected: $arch ($ARCH_RAW)"

stop_existing_tailscale() {
  echo "Stopping any existing Tailscale..."

  # Stop via Batocera service manager (if present)
  if command -v batocera-services >/dev/null 2>&1; then
    batocera-services stop tailscale >/dev/null 2>&1 || true
    batocera-services disable tailscale >/dev/null 2>&1 || true
  fi

  # Stop any tailscale binaries previously started outside the service
  if command -v /userdata/tailscale/tailscale >/dev/null 2>&1; then
    /userdata/tailscale/tailscale down >/dev/null 2>&1 || true
  fi

  # Kill lingering daemons (best-effort)
  pkill -x tailscaled >/dev/null 2>&1 || true
  pkill -x tailscale  >/dev/null 2>&1 || true

  # Wait briefly for shutdown to complete
  for _ in 1 2 3 4 5; do
    pgrep -x tailscaled >/dev/null 2>&1 || break
    sleep 0.2
  done

  if pgrep -x tailscaled >/dev/null 2>&1; then
    echo "tailscaled is still running; forcing stop..." >&2
    pkill -9 -x tailscaled >/dev/null 2>&1 || true
  fi
}

check_tun() {
  if [[ -c /dev/net/tun ]]; then
    return 0
  fi

  echo "TUN device not found. Attempting to load tun module..."

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun >/dev/null 2>&1 || true
  fi

  if [[ ! -c /dev/net/tun ]]; then
    echo "ERROR: TUN device is not available. Kernel may lack CONFIG_TUN." >&2
    exit 1
  fi
}

backup_config() {
    local file="$1"
    cp "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
}

update_config_key() {
    local key="$1"
    local value="$2"
    local file="$3"

    local escaped_value
    escaped_value=$(printf '%s\n' "$value" | sed 's/[&/\]/\\&/g')

    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${escaped_value}|" "$file"
    else
        printf "\n%s=%s\n" "$key" "$escaped_value" >> "$file"
    fi
}

valid_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local ip mask
    ip="${cidr%/*}"
    mask="${cidr#*/}"
    (( mask >= 0 && mask <= 32 )) || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

perform_auth_login() {
    if [[ -z "$AUTH_KEY" ]]; then
        return 0
    fi

    echo
    echo "Authenticating with provided auth key..."

    # Ensure tailscaled running
    if ! pgrep -x tailscaled >/dev/null 2>&1; then
        "$INSTALL_DIR/tailscaled" -state "$INSTALL_DIR/state" >/dev/null 2>&1 &
        sleep 2
    fi

    if ! "$INSTALL_DIR/tailscale" up --auth-key="$AUTH_KEY" >/dev/null 2>&1; then
        echo "ERROR: Auth key login failed."
        exit 1
    fi

    echo "Authentication successful."
}

run_config_wizard() {
    echo
    echo "========== Tailscale Configuration =========="
    echo

    # Helper functions
    prompt_yes_no() {
        local prompt="$1"
        local default="$2"   # 1 = yes, 0 = no
        local reply

        if [[ "$default" -eq 1 ]]; then
            read -rp "$prompt (Y/n): " reply
            [[ "$reply" =~ ^[Nn]$ ]] && echo 0 || echo 1
        else
            read -rp "$prompt (y/N): " reply
            [[ "$reply" =~ ^[Yy]$ ]] && echo 1 || echo 0
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
    DEFAULT_CIDR="$(ip -o -4 route show dev "$DEFAULT_IFACE" scope link proto kernel 2>/dev/null | awk '{print $1; exit}')"

    echo "Detected interface: ${DEFAULT_IFACE:-unknown}"
    echo "Detected subnet:    ${DEFAULT_CIDR:-unknown}"
    echo

    # Basic Options
    echo "----- Basic Options -----"
    echo

    # Advertise subnet
    if [[ -n "$DEFAULT_CIDR" && "$(prompt_yes_no "Advertise this subnet to your tailnet?" 0)" -eq 1 ]]; then
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
        if [[ -n "$EXIT_NODE_RAW" ]]; then
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
        [[ -n "$HOST_RAW" ]] && HOSTNAME="\"$HOST_RAW\""

        read -rp "Netfilter mode (on/off/nodivert, leave blank for default): " NF_RAW
        if [[ "$NF_RAW" =~ ^(on|off|nodivert)$ ]]; then
            NETFILTER_MODE="\"$NF_RAW\""
        fi
    fi

    # Save Configuration
    echo
    echo "Updating configuration..."

    [[ -f "$CONFIG_FILE" ]] && backup_config "$CONFIG_FILE"

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

cd "$TMPDIR"

TS_VER="$(
curl -fsSL "$PKGS" |
  grep -oE "tailscale_[0-9]+\.[0-9]+\.[0-9]+_${arch}\.tgz" |
  sed -E "s/^tailscale_([0-9]+\.[0-9]+\.[0-9]+)_${arch}\.tgz/\1/" |
  sort -V |
  tail -n1
)"

[[ -n "${TS_VER:-}" ]] || { echo "Could not detect latest Tailscale version" >&2; exit 1; }

if [[ "$FORCE" -eq 0 && "$CURRENT_VERSION" == "$TS_VER" ]]; then
  echo "Tailscale $TS_VER already installed. Skipping installation."
  exit 0
fi

if [[ "$FORCE" -eq 1 ]]; then
  echo "Force flag detected — reinstalling Tailscale $TS_VER"
elif [[ -n "$CURRENT_VERSION" ]]; then
  echo "Upgrading from $CURRENT_VERSION → $TS_VER"
else
  echo "Fresh install of Tailscale $TS_VER"
fi

TGZ="tailscale_${TS_VER}_${arch}.tgz"
URL="${PKGS}${TGZ}"
EXPECTED_DIR="tailscale_${TS_VER}_${arch}"

echo "Selected version: $TS_VER"
echo "Target archive: $TGZ"

# Download release metadata
echo "Downloading signed checksums..."
curl -fLO "${PKGS}SHA256SUMS"
curl -fLO "${PKGS}SHA256SUMS.sig"

# Import Tailscale release key
echo "Importing Tailscale signing key..."

curl -fsSL https://pkgs.tailscale.com/stable/tailscale.asc | gpg --import >/dev/null 2>&1

# Verify fingerprint matches expected
IMPORTED_FPR="$(gpg --with-colons --fingerprint | awk -F: '/^fpr:/ {print $10}' | head -n1)"

if [[ "$IMPORTED_FPR" != "$GPG_KEY_FPR" ]]; then
  echo "ERROR: GPG fingerprint mismatch!" >&2
  echo "Expected: $GPG_KEY_FPR" >&2
  echo "Got:      $IMPORTED_FPR" >&2
  exit 1
fi

echo "GPG fingerprint verified."

# Verify signature
echo "Verifying SHA256SUMS signature..."

if ! gpg --verify SHA256SUMS.sig SHA256SUMS >/dev/null 2>&1; then
  echo "ERROR: Signature verification failed!" >&2
  exit 1
fi

echo "Signature verification successful."

# Download archive
echo "Downloading $TGZ..."
curl -fLO --connect-timeout 15 --max-time 600 "$URL"

# Verify checksum from signed file
echo "Verifying archive checksum..."

if ! grep " $TGZ\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1; then
  echo "ERROR: Checksum verification failed!" >&2
  rm -f "$TGZ"
  exit 1
fi

echo "Checksum verification successful."

# Ensure the download exists and is non-empty
if [[ ! -s "$TGZ" ]]; then
  echo "ERROR: Download missing or empty: $TMPDIR/$TGZ" >&2
  exit 1
fi

echo "Extracting archive..."

tar --no-same-owner --no-same-permissions -xzf "$TGZ"

# Ensure exactly one matching directory exists
MATCHES=()
while IFS= read -r -d '' d; do
  MATCHES+=("$d")
done < <(find . -maxdepth 1 -type d -name "$EXPECTED_DIR" -print0)

if [[ "${#MATCHES[@]}" -ne 1 ]]; then
  echo "ERROR: Expected exactly one directory named $EXPECTED_DIR, found ${#MATCHES[@]}" >&2
  echo "Directory contents:" >&2
  ls -la >&2
  exit 1
fi

EXTRACTED_DIR="${MATCHES[0]#./}"

# Validate required binaries exist and are executable
if [[ ! -x "$EXTRACTED_DIR/tailscale" ]]; then
  echo "ERROR: tailscale binary missing or not executable" >&2
  exit 1
fi

if [[ ! -x "$EXTRACTED_DIR/tailscaled" ]]; then
  echo "ERROR: tailscaled binary missing or not executable" >&2
  exit 1
fi

echo "Extraction verified: $TMPDIR/$EXTRACTED_DIR"

echo "Stopping existing service before install..."
stop_existing_tailscale

rm -rf "$TMP_INSTALL_DIR"
mkdir -p "$TMP_INSTALL_DIR"

# Install into temp staging directory
install -m 0755 "$EXTRACTED_DIR/tailscale"  "$TMP_INSTALL_DIR/tailscale"
install -m 0755 "$EXTRACTED_DIR/tailscaled" "$TMP_INSTALL_DIR/tailscaled"

# Move into place atomically
mv "$TMP_INSTALL_DIR/tailscale"  "$INSTALL_DIR/tailscale"
mv "$TMP_INSTALL_DIR/tailscaled" "$INSTALL_DIR/tailscaled"

rm -rf "$TMP_INSTALL_DIR"

echo "$TS_VER" > "$INSTALLED_VERSION_FILE"

echo "Checking for tun device."
check_tun

echo "Checking configuration..."

# Copy template if config missing
if [[ ! -f "$CONFIG_FILE" ]]; then
    if [[ -f "$CONFIG_TEMPLATE" ]]; then
        echo "No config found. Installing default template."
        cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
    else
        echo "WARNING: config.conf.template not found. Skipping config setup."
    fi
fi

if [[ -z "$AUTH_KEY" && "$NONINTERACTIVE" -eq 0 ]]; then
    echo
    read -rsp "Enter Tailscale auth key (leave blank to skip): " INPUT_KEY
    echo
    AUTH_KEY="$INPUT_KEY"
fi

perform_auth_login

# Ask user if they want configuration
if [[ -f "$CONFIG_FILE" ]]; then
    echo
    read -rp "Would you like to configure Tailscale now? (y/N): " DO_CONFIG
    if [[ "$DO_CONFIG" =~ ^[Yy]$ ]]; then
        run_config_wizard
    else
        echo "Skipping configuration. You can edit $CONFIG_FILE manually."
    fi
fi

echo "Tailscale $TS_VER installed successfully."
