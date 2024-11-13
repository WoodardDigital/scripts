#!/bin/bash

# Default settings
DURATION=600   # Default duration (10 minutes)
INTERVAL=15    # Interval between MTR runs
PACKETS=10     # Number of packets per MTR run

# Function to display usage
usage() {
  echo "Usage: $0 --IPADDRESS [--duration DURATION_IN_SECONDS]"
  echo "  --IPADDRESS       The IP address to run MTR against"
  echo "  --duration        Optional: specify custom duration in seconds (default is 600 seconds)"
  exit 1
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --*)
      IPADDRESS="${1#--}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# Check if IP address is provided
if [ -z "$IPADDRESS" ]; then
  echo "Error: IP address is required."
  usage
fi

LOGFILE="${IPADDRESS}.log"

# Calculate the end time
end_time=$((SECONDS + DURATION))

echo "Starting MTR to $IPADDRESS for $DURATION seconds. Logging to $LOGFILE..."

# Run the MTR command in a loop until the duration ends
while [ $SECONDS -lt $end_time ]; do
  echo "Running MTR to $IPADDRESS at $(date)" | tee -a "$LOGFILE"
  mtr -rwbzc "$PACKETS" "$IPADDRESS" | tee -a "$LOGFILE"
  echo "----------------------------------------" | tee -a "$LOGFILE"
  sleep $INTERVAL
done

echo "MTR completed for $IPADDRESS. Results saved in $LOGFILE."

