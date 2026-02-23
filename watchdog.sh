#!/bin/bash
# /userdata/tailscale/watchdog.sh - Keeps monitor.sh alive

set -u

MONITOR_SCRIPT="/userdata/tailscale/monitor.sh"
LOGFILE="/userdata/tailscale/watchdog.log"
PIDFILE="/var/run/tailscale-watchdog.pid"
MAX_RETRIES=5      # Number of consecutive crashes before backoff
BACKOFF_TIME=30    # Seconds to wait after MAX_RETRIES
RESTART_COUNT=0

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
  echo "$(date) - Monitor script exited with code $rc"

  RESTART_COUNT=$((RESTART_COUNT+1))

  if [[ $RESTART_COUNT -ge $MAX_RETRIES ]]; then
    echo "$(date) - Monitor crashed $RESTART_COUNT times consecutively. Backing off for $BACKOFF_TIME seconds..."
    sleep "$BACKOFF_TIME"
    RESTART_COUNT=0
  else
    echo "$(date) - Restarting monitor in 5 seconds..."
    sleep 5
  fi
done