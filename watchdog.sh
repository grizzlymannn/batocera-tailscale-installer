#!/bin/bash
# /userdata/tailscale/watchdog.sh - Keeps monitor.sh alive

set -u

INSTALL_DIR="/userdata/tailscale"
MONITOR_SCRIPT="$INSTALL_DIR//monitor.sh"
LOGFILE="$INSTALL_DIR/logs/watchdog.log"
PIDFILE="$INSTALL_DIR/tailscale-watchdog.pid"
RESTART_COUNT=0
BACKOFF=5          # Initial backoff in seconds
MAX_BACKOFF=120    # Maximum wait time

mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$PIDFILE")"

# Write PID file so manual launches are tracked
echo $$ > "$PIDFILE"

exec >>"$LOGFILE" 2>&1
echo "$(date) - Tailscale watchdog started (PID $$)"

cleanup() {
  echo "$(date) - Watchdog stopping, cleaning up..."
  # Kill our child processes (monitor, and anything it started in our process tree).
  pkill -P $$ 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 0
}

trap cleanup SIGTERM SIGINT

if [ ! -x "$MONITOR_SCRIPT" ]; then
  echo "$(date) - ERROR: monitor not executable: $MONITOR_SCRIPT"
  exit 1
fi

while true; do
    echo "$(date) - Starting monitor script..."
    "$MONITOR_SCRIPT" &
    MONITOR_PID=$!

    wait "$MONITOR_PID"
    rc=$?
    echo "$(date) - Monitor exited with code $rc"

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
        BACKOFF=$(( BACKOFF * 2 ))
        (( BACKOFF > MAX_BACKOFF )) && BACKOFF=$MAX_BACKOFF
    fi
done