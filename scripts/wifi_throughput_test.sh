#!/usr/bin/env bash
# Raw TCP throughput test between phone (Android) and this Mac.
# Bypasses NotifMirror entirely — pure kernel + Wi-Fi.
#
# Phone streams 50 MB of /dev/zero over TCP to a local nc listener;
# we time the total and compute MB/s. If this is slow (e.g. < 10 MB/s),
# the Wi-Fi link itself is the bottleneck and no app-level change
# will fix it.
#
# Requirements:
#   - adb in $PATH with a device authorized (wireless or USB)
#   - nc (BSD netcat) — shipped with macOS
#   - Phone and Mac on the same LAN
#
# Usage:
#   ./scripts/wifi_throughput_test.sh
#   # or force a specific Mac IP:
#   MAC_IP=192.168.1.103 ./scripts/wifi_throughput_test.sh

set -u

PORT="${PORT:-8892}"
MB="${MB:-500}"                  # total payload size
CHUNK_KB="${CHUNK_KB:-64}"      # dd block size
OUT="/tmp/wifi_throughput_test.out"

# ---- 1. Figure out Mac's LAN IP ----
if [[ -z "${MAC_IP:-}" ]]; then
  MAC_IP="$(ifconfig en0 2>/dev/null | awk '/inet / {print $2; exit}')"
fi
if [[ -z "${MAC_IP}" ]]; then
  echo "ERROR: could not determine Mac LAN IP; export MAC_IP=..." >&2
  exit 1
fi

echo "Mac LAN IP: $MAC_IP"
echo "Port: $PORT"
echo "Payload: ${MB} MB (${CHUNK_KB} KiB blocks)"
echo

# ---- 2. Sanity check adb ----
DEVICES=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
if [[ -z "$DEVICES" ]]; then
  echo "ERROR: no authorized adb device." >&2
  exit 1
fi
echo "Device: $(echo "$DEVICES" | head -1)"

# ---- 3. Make sure the port is free ----
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT already in use; pick another with PORT=XXXX env var." >&2
  exit 1
fi

# ---- 4. Launch nc listener (discard all bytes, count them) ----
rm -f "$OUT"
# nc -l <port> : listen on port (BSD nc syntax)
# pipe to wc -c : count total bytes received
# run in background, capture total to file
( nc -l "$PORT" | wc -c > "$OUT" ) &
NC_PID=$!
sleep 0.4

# Confirm listener is actually up
if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ERROR: nc listener didn't come up." >&2
  kill $NC_PID 2>/dev/null
  exit 1
fi
echo "nc listener up (pid $NC_PID)"
echo

# ---- 5. Phone → Mac: stream zeros over TCP ----
# bs * count = total bytes
COUNT=$(( MB * 1024 / CHUNK_KB ))
START=$(date +%s.%N)

echo ">>> Sending ${MB} MB phone → $MAC_IP:$PORT ..."
adb shell "dd if=/dev/zero bs=$((CHUNK_KB * 1024)) count=$COUNT 2>/dev/null | nc $MAC_IP $PORT"
SEND_RC=$?

END=$(date +%s.%N)

# ---- 6. Wait for nc to flush its byte counter and exit ----
wait $NC_PID 2>/dev/null

# ---- 7. Report ----
BYTES=$(cat "$OUT" 2>/dev/null || echo 0)
BYTES=$(echo "$BYTES" | tr -d ' ')

DUR=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.3f", e - s }')
if (( $(awk -v d="$DUR" 'BEGIN{print (d>0)}') == 1 )); then
  MBPS=$(awk -v b="$BYTES" -v d="$DUR" 'BEGIN { printf "%.2f", (b/1048576)/d }')
  MBITS=$(awk -v b="$BYTES" -v d="$DUR" 'BEGIN { printf "%.2f", (b*8/1000000)/d }')
else
  MBPS="?"
  MBITS="?"
fi

echo
echo "================ RESULT ================"
echo "Bytes received:  $BYTES"
echo "Elapsed:         ${DUR} s"
echo "Throughput:      ${MBPS} MB/s  (${MBITS} Mbps)"
echo "adb exit code:   $SEND_RC"
echo "========================================"

if [[ "$BYTES" -lt $(( MB * 1024 * 1024 * 9 / 10 )) ]]; then
  echo
  echo "WARNING: received only $BYTES bytes (< 90% of ${MB} MB)."
  echo "Connection likely got cut short. Interpret throughput with care."
fi
