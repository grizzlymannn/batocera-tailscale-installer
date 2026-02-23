#!/bin/bash
# /userdata/tailscale/monitor.sh

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# ----------------------------
# Paths and state
# ----------------------------
INSTALL_DIR="/userdata/tailscale"
DAEMON="$INSTALL_DIR/tailscaled"
CLIENT="$INSTALL_DIR/tailscale"
STATE="$INSTALL_DIR/state"
CONFIG_FILE="$INSTALL_DIR/config.conf"
LOGFILE="$INSTALL_DIR/logs/monitor.log"
STATEFILE="/tmp/tailscale-network-state"

mkdir -p "$(dirname "$LOGFILE")" "$INSTALL_DIR"
exec >>"$LOGFILE" 2>&1

echo "$(date) - Monitor starting (PID $$)"

# ----------------------------
# Dependency check
# ----------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "$(date) - ERROR: missing required tool: $1"; exit 1; }; }

for cmd in ip timeout awk grep pgrep pkill; do need "$cmd"; done

for f in "$DAEMON" "$CLIENT"; do
    [ -x "$f" ] || { echo "$(date) - ERROR: required executable missing: $f"; exit 1; }
done

# ----------------------------
# Load configuration
# ----------------------------
source "$CONFIG_FILE" || true

# Apply safe defaults
: "${ADVERTISE_ROUTES:=}"
: "${SNAT_SUBNET_ROUTES:=1}"
: "${ADVERTISE_EXIT_NODE:=0}"
: "${ACCEPT_ROUTES:=0}"
: "${EXIT_NODE:=}"
: "${EXIT_NODE_ALLOW_LAN_ACCESS:=0}"
: "${ACCEPT_DNS:=1}"
: "${SHIELDS_UP:=0}"
: "${HOSTNAME:=}"
: "${NETFILTER_MODE:=on}"
: "${STATEFUL_FILTERING:=0}"

# ----------------------------
# Utility functions
# ----------------------------
get_network() {
    INTERFACE="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    CIDR=""

    [[ -n "$INTERFACE" ]] || return 0

    # kernel subnet route
    CIDR="$(ip -o -4 route show dev "$INTERFACE" scope link proto kernel 2>/dev/null | awk '{print $1; exit}')"

    # fallback
    if [[ -z "$CIDR" ]]; then
        CIDR="$(ip -o -f inet addr show "$INTERFACE" 2>/dev/null | awk '{print $4; exit}')"
    fi
}

tailscaled_running() { pgrep -x tailscaled >/dev/null 2>&1; }
tailscaled_responsive() { tailscaled_running && timeout 5 "$CLIENT" status >/dev/null 2>&1; }

start_tailscaled() {
    echo "$(date) - Starting tailscaled..."
    "$DAEMON" -state "$STATE" >>"$INSTALL_DIR/tailscaled.log" 2>&1 &
    sleep 2
}

ensure_tailscaled() {
    if tailscaled_responsive; then return 0; fi

    if ! tailscaled_running; then
        echo "$(date) - Tailscaled not running, starting..."
        start_tailscaled
    else
        echo "$(date) - Tailscaled running but unresponsive, restarting..."
        pkill -x tailscaled || true
        sleep 1
        start_tailscaled
    fi

    tailscaled_responsive || { echo "$(date) - Tailscaled still not responsive"; return 1; }
    return 0
}

# -----------------------------------------
# Build Tailscale command safely (null-separated)
# -----------------------------------------
build_tailscale_cmd() {
    local CMD=("$CLIENT" up -state "$STATE")

    [[ -n "${ADVERTISE_ROUTES:-}" ]] && CMD+=("--advertise-routes=$ADVERTISE_ROUTES" "--snat-subnet-routes=${SNAT_SUBNET_ROUTES:-1}")
    [[ "${ADVERTISE_EXIT_NODE:-0}" -eq 1 ]] && CMD+=("--advertise-exit-node")
    [[ -n "${EXIT_NODE:-}" ]] && CMD+=("--exit-node=$EXIT_NODE" "--exit-node-allow-lan-access=${EXIT_NODE_ALLOW_LAN_ACCESS:-0}")
    [[ "${ACCEPT_ROUTES:-0}" -eq 1 ]] && CMD+=("--accept-routes=1")
    [[ "${ACCEPT_DNS:-0}" -eq 1 ]] && CMD+=("--accept-dns=1")
    [[ "${SHIELDS_UP:-0}" -eq 1 ]] && CMD+=("--shields-up=1")
    [[ -n "${HOSTNAME:-}" ]] && CMD+=("--hostname=$HOSTNAME")
    [[ -n "${NETFILTER_MODE:-}" ]] && CMD+=("--netfilter-mode=$NETFILTER_MODE")
    [[ "${STATEFUL_FILTERING:-0}" -eq 1 ]] && CMD+=("--stateful-filtering=1")

    # null-separated for safe array assignment
    printf '%s\0' "${CMD[@]}"
}

# -----------------------------------------
# Apply configuration
# -----------------------------------------
apply_tailscale_config() {
    get_network
    [[ -z "$CIDR" ]] && { echo "$(date) - No valid network detected, skipping"; return; }

    ensure_tailscaled || return

    # read null-separated command into array
    mapfile -d '' CMD < <(build_tailscale_cmd)

    echo "$(date) - Running Tailscale command: ${CMD[*]}"
    if ! "${CMD[@]}" >/dev/null 2>&1; then
        echo "$(date) - Warning: tailscale up returned non-zero"
    else
        echo "$(date) - Tailscale configuration applied successfully"
    fi
}

# ----------------------------
# Cleanup
# ----------------------------
cleanup() {
    echo "$(date) - Monitor stopping"
    rm -f "$STATEFILE"
    exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# ----------------------------
# Initial network detection & apply
# ----------------------------
echo "$(date) - Waiting for initial network (max 60s)..."
for i in $(seq 1 60); do
    get_network
    [[ -n "$CIDR" ]] && break
    sleep 1
done
echo "$(date) - Initial network: $INTERFACE / $CIDR"

echo "$INTERFACE|$CIDR" >"$STATEFILE"
apply_tailscale_config

# -----------------------------------------
# Monitor loop
# -----------------------------------------
LAST_INTERFACE=""; LAST_CIDR=""

echo "$(date) - Starting network monitor loop..."

while true; do
    # reset initial state from file if exists
    [[ -f "$STATEFILE" ]] && IFS='|' read -r LAST_INTERFACE LAST_CIDR <"$STATEFILE"

    # monitor network changes
    ip monitor link route 2>/dev/null | while read -r; do
        sleep 2
        get_network
        if [[ "$INTERFACE" != "$LAST_INTERFACE" ]] || [[ "$CIDR" != "$LAST_CIDR" ]]; then
            echo "$(date) - Network changed: [$LAST_INTERFACE/$LAST_CIDR] -> [$INTERFACE/$CIDR]"
            echo "$INTERFACE|$CIDR" >"$STATEFILE"
            LAST_INTERFACE="$INTERFACE"
            LAST_CIDR="$CIDR"
            apply_tailscale_config
        fi
    done

    echo "$(date) - ip monitor exited unexpectedly, retrying in 5s..."
    sleep 5
done