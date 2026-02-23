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
exec >> "$LOGFILE" 2>&1

echo "$(date) - Monitor starting (PID $$)"

# ----------------------------
# Dependency check
# ----------------------------
need() { command -v "$1" > /dev/null 2>&1 || {
  echo "$(date) - ERROR: missing required tool: $1"
  exit 1
}; }

for cmd in ip timeout awk grep; do need "$cmd"; done

for f in "$DAEMON" "$CLIENT"; do
  [ -x "$f" ] || {
    echo "$(date) - ERROR: required executable missing: $f"
    exit 1
  }
done

# Detect availability of process utilities (pgrep/pkill/pidof) and adapt
PGREP_AVAILABLE=0
if command -v pgrep > /dev/null 2>&1; then
  PGREP_AVAILABLE=1
fi
PKILL_AVAILABLE=0
if command -v pkill > /dev/null 2>&1; then
  PKILL_AVAILABLE=1
fi
PIDOF_AVAILABLE=0
if command -v pidof > /dev/null 2>&1; then
  PIDOF_AVAILABLE=1
fi

# ----------------------------
# Load configuration
# ----------------------------
# shellcheck source=/dev/null
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"

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
  INTERFACE="$(ip -o -4 route show default 2> /dev/null | awk '{print $5; exit}')"
  CIDR=""

  [[ -n $INTERFACE ]] || return 0

  # kernel subnet route
  CIDR="$(ip -o -4 route show dev "$INTERFACE" scope link proto kernel 2> /dev/null | awk '{print $1; exit}')"

  # fallback
  if [[ -z $CIDR ]]; then
    CIDR="$(ip -o -f inet addr show "$INTERFACE" 2> /dev/null | awk '{print $4; exit}')"
  fi
}

tailscaled_running() {
  if [[ $PGREP_AVAILABLE -eq 1 ]]; then
    pgrep -x tailscaled > /dev/null 2>&1
    return $?
  fi
  if [[ $PIDOF_AVAILABLE -eq 1 ]]; then
    pidof tailscaled > /dev/null 2>&1
    return $?
  fi

  echo "$(date) - Warning: pgrep and pidof not available, falling back to ps for process detection"
  if ps -eo comm | grep -x tailscaled > /dev/null 2>&1; then
    return 0
  fi

  return 1
}

tailscaled_responsive() { tailscaled_running && timeout 5 "$CLIENT" status > /dev/null 2>&1; }

start_tailscaled() {
  echo "$(date) - Starting tailscaled..."
  "$DAEMON" -state "$STATE" >> "$INSTALL_DIR/logs/tailscaled.log" 2>&1 &
  sleep 2
}

ensure_tailscaled() {
  if tailscaled_responsive; then return 0; fi

  if ! tailscaled_running; then
    echo "$(date) - Tailscaled not running, starting..."
    start_tailscaled
  else
    echo "$(date) - Tailscaled running but unresponsive, restarting..."
    if [[ $PKILL_AVAILABLE -eq 1 ]]; then
      pkill -x tailscaled || true
    elif [[ $PIDOF_AVAILABLE -eq 1 ]]; then
      for pid in $(pidof tailscaled 2> /dev/null || true); do
        kill -TERM "$pid" 2> /dev/null || true
      done
    else
      # Last resort: parse ps output for PIDs
      for pid in $(ps -eo pid,comm | awk '/tailscaled$/ {print $1}'); do
        kill -TERM "$pid" 2> /dev/null || true
      done
    fi
    sleep 1
    start_tailscaled
  fi

  tailscaled_responsive || {
    echo "$(date) - Tailscaled still not responsive"
    return 1
  }
  return 0
}

# -----------------------------------------
# Build Tailscale command safely (null-separated)
# -----------------------------------------
strip_quotes() {
  local v="$1"
  # remove a single leading and trailing double-quote if present
  v="${v#\"}"
  v="${v%\"}"
  printf '%s' "$v"
}

build_tailscale_cmd() {
  local CMD=("$CLIENT" up --reset)

  local AR
  AR=$(strip_quotes "${ADVERTISE_ROUTES:-}")
  if [[ -n $AR ]]; then
    CMD+=("--advertise-routes=$AR" "--snat-subnet-routes=${SNAT_SUBNET_ROUTES:-1}")
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true
  fi

  if [[ ${ADVERTISE_EXIT_NODE:-0} -eq 1 ]]; then
    CMD+=("--advertise-exit-node")
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1 || true
  fi

  local EN
  EN=$(strip_quotes "${EXIT_NODE:-}")
  [[ -n $EN ]] && CMD+=("--exit-node=$EN" "--exit-node-allow-lan-access=${EXIT_NODE_ALLOW_LAN_ACCESS:-0}")

  [[ ${ACCEPT_ROUTES:-0} -eq 1 ]] && CMD+=("--accept-routes=1")
  [[ ${ACCEPT_DNS:-0} -eq 1 ]] && CMD+=("--accept-dns=1")
  [[ ${SHIELDS_UP:-0} -eq 1 ]] && CMD+=("--shields-up=1")

  local HN
  HN=$(strip_quotes "${HOSTNAME:-}")
  [[ -n $HN ]] && CMD+=("--hostname=$HN")

  local NF
  NF=$(strip_quotes "${NETFILTER_MODE:-}")
  [[ -n $NF ]] && CMD+=("--netfilter-mode=$NF")

  [[ ${STATEFUL_FILTERING:-0} -eq 1 ]] && CMD+=("--stateful-filtering=1")

  # null-separated for safe array assignment
  printf '%s\0' "${CMD[@]}"
}

# -----------------------------------------
# Apply configuration
# -----------------------------------------
apply_tailscale_config() {
  get_network
  [[ -z $CIDR ]] && {
    echo "$(date) - No valid network detected, skipping"
    return
  }

  ensure_tailscaled || return

  # read null-separated command into array (use -t to strip the delimiter)
  mapfile -d $'\0' -t CMD < <(build_tailscale_cmd)

  echo "$(date) - Running Tailscale command: ${CMD[*]}"
  # Capture output and exit code to aid debugging when `tailscale up` fails
  max_lines=50
  if output="$("${CMD[@]}" 2>&1)"; then
    echo "$(date) - Tailscale configuration applied successfully"

    if [[ -n $output ]]; then
      echo "$(date) - tailscale up output:"
      printf '%s\n' "$output" | tail -n "$max_lines"
    fi
  else
    rc=$?
    echo "$(date) - Warning: tailscale up returned non-zero (exit $rc)"

    if [[ -n $output ]]; then
      echo "$(date) - tailscale up output:"
      printf '%s\n' "$output" | tail -n "$max_lines"
    else
      echo "$(date) - tailscale up produced no output"
    fi
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
  [[ -n $CIDR ]] && break
  sleep 1
done
echo "$(date) - Initial network: $INTERFACE / $CIDR"

echo "$INTERFACE|$CIDR" > "$STATEFILE"
apply_tailscale_config

# -----------------------------------------
# Monitor loop
# -----------------------------------------
LAST_INTERFACE=""
LAST_CIDR=""

echo "$(date) - Starting network monitor loop..."

while true; do
  # reset initial state from file if exists
  [[ -f $STATEFILE ]] && IFS='|' read -r LAST_INTERFACE LAST_CIDR < "$STATEFILE"

  # monitor network changes (run loop in current shell via process substitution)
  while read -r; do
    sleep 2
    get_network
    if [[ $INTERFACE != "$LAST_INTERFACE" ]] || [[ $CIDR != "$LAST_CIDR" ]]; then
      echo "$(date) - Network changed: [$LAST_INTERFACE/$LAST_CIDR] -> [$INTERFACE/$CIDR]"
      echo "$INTERFACE|$CIDR" > "$STATEFILE"
      LAST_INTERFACE="$INTERFACE"
      LAST_CIDR="$CIDR"
      apply_tailscale_config
    fi
  done < <(ip monitor link route 2> /dev/null)

  echo "$(date) - ip monitor exited unexpectedly, retrying in 5s..."
  sleep 5
done
