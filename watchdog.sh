#!/bin/bash
# /userdata/tailscale/watchdog.sh - Keeps monitor.sh alive

set -u

INSTALL_DIR="/userdata/tailscale"
MONITOR_SCRIPT="$INSTALL_DIR/monitor.sh"
LOGFILE="$INSTALL_DIR/logs/watchdog.log"
PIDFILE="$INSTALL_DIR/tailscale-watchdog.pid"
RESTART_COUNT=0
BACKOFF=5                         # Initial backoff in seconds
MAX_BACKOFF=120                   # Maximum wait time
MAX_LOG_SIZE=$((2 * 1024 * 1024)) # 2MB
MAX_LOG_BACKUPS=3

mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$PIDFILE")"

# Detect whether `pkill` is available
PKILL_AVAILABLE=0
if command -v pkill > /dev/null 2>&1; then
  PKILL_AVAILABLE=1
fi

# Detect whether `setsid` is available to start monitor in its own session
SETSID_AVAILABLE=0
if command -v setsid > /dev/null 2>&1; then
  SETSID_AVAILABLE=1
fi

# Prevent multiple watchdog instances using PID file
if [[ -f $PIDFILE ]]; then
  oldpid=$(cat "$PIDFILE" 2> /dev/null || true)
  if [[ -n $oldpid && $oldpid =~ ^[0-9]+$ ]]; then
    if kill -0 "$oldpid" 2> /dev/null; then
      # Verify the PID actually belongs to our watchdog/monitor by checking cmdline
      if [[ -r "/proc/$oldpid/cmdline" ]] && grep -Fq "$MONITOR_SCRIPT" "/proc/$oldpid/cmdline"; then
        echo "$(date) - Watchdog already running (PID $oldpid), exiting."
        exit 0
      else
        echo "$(date) - PID $oldpid exists but is not watchdog; removing stale PID file."
        rm -f "$PIDFILE"
      fi
    else
      echo "$(date) - No process with PID $oldpid; removing stale PID file."
      rm -f "$PIDFILE"
    fi
  else
    echo "$(date) - Invalid PID in PID file; removing."
    rm -f "$PIDFILE"
  fi
fi

# Write PID file so manual launches are tracked
echo $$ > "$PIDFILE"

# Track monitor PID so cleanup can target its process group
MONITOR_PID=0

exec >> "$LOGFILE" 2>&1
echo "$(date) - Tailscale watchdog started (PID $$)"

cleanup() {
  echo "$(date) - Watchdog stopping, cleaning up..."
  # Kill our child processes (monitor, and anything it started in our process tree).
  kill_descendants() {
    local parent="$1"
    if [[ $PKILL_AVAILABLE -eq 1 ]]; then
      pkill -P "$parent" 2> /dev/null || true
      return
    fi
    # Try using pgrep -P if available
    if command -v pgrep > /dev/null 2>&1; then
      local child
      for child in $(pgrep -P "$parent" 2> /dev/null || true); do
        kill_descendants "$child"
        kill -TERM "$child" 2> /dev/null || true
      done
      return
    fi
    # Last fallback: use ps to find direct children
    local child
    for child in $(ps -o pid= --ppid "$parent" 2> /dev/null); do
      kill_descendants "$child"
      kill -TERM "$child" 2> /dev/null || true
    done
  }

  # If we started the monitor in its own session, kill the process group first
  if [[ -n $MONITOR_PID && $MONITOR_PID =~ ^[0-9]+$ && $MONITOR_PID -gt 0 ]] && [[ $SETSID_AVAILABLE -eq 1 ]]; then
    echo "$(date) - Stopping monitor process group: -$MONITOR_PID"
    kill -TERM -"$MONITOR_PID" 2> /dev/null || true
    sleep 2
    kill -KILL -"$MONITOR_PID" 2> /dev/null || true
  else
    echo "$(date) - Stopping monitor process and descendants with 'kill_descendants'"
    kill_descendants $$
  fi
  rm -f "$PIDFILE"
  sleep 1
  exit 0
}

rotate_log_if_needed() {
  local file="$1"

  [[ -f $file ]] || return 0

  local size
  size=$(stat -c%s "$file" 2> /dev/null || echo 0)

  ((size <= MAX_LOG_SIZE)) && return 0

  echo "$(date) - Rotating $file (size: $size bytes)"

  # Remove oldest backup if exceeding limit
  if [[ -f "$file.$MAX_LOG_BACKUPS" ]]; then
    rm -f "$file.$MAX_LOG_BACKUPS"
  fi

  # Shift backups upward
  for ((i = MAX_LOG_BACKUPS - 1; i >= 1; i--)); do
    if [[ -f "$file.$i" ]]; then
      mv "$file.$i" "$file.$((i + 1))"
    fi
  done

  # Move current log to .1
  mv "$file" "$file.1"
}

trap cleanup SIGTERM SIGINT EXIT

if [ ! -x "$MONITOR_SCRIPT" ]; then
  echo "$(date) - ERROR: monitor not executable: $MONITOR_SCRIPT"
  exit 1
fi

while true; do
  echo "$(date) - Starting monitor script..."
  if [[ $SETSID_AVAILABLE -eq 1 ]]; then
    setsid "$MONITOR_SCRIPT" > /dev/null 2>&1 &
  else
    "$MONITOR_SCRIPT" > /dev/null 2>&1 &
  fi
  MONITOR_PID=$!

  wait "$MONITOR_PID"
  rc=$?
  echo "$(date) - Monitor exited with code $rc"

  rotate_log_if_needed "$INSTALL_DIR/logs/monitor.log"
  rotate_log_if_needed "$INSTALL_DIR/logs/tailscaled.log"
  rotate_log_if_needed "$LOGFILE"

  if [[ $rc -eq 0 ]]; then
    # Normal exit resets counters
    RESTART_COUNT=0
    BACKOFF=5
  else
    RESTART_COUNT=$((RESTART_COUNT + 1))
    echo "$(date) - Monitor crashed $RESTART_COUNT times"

    # Wait with exponential backoff
    echo "$(date) - Waiting $BACKOFF seconds before restart..."
    sleep "$BACKOFF"

    # Double backoff, but do not exceed MAX_BACKOFF
    BACKOFF=$((BACKOFF * 2))
    ((BACKOFF > MAX_BACKOFF)) && BACKOFF=$MAX_BACKOFF
  fi
done
