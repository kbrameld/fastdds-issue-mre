#!/bin/bash
# Fast DDS TypeLookup reproducer. Starts one "server" participant that publishes TYPES topics, each with a different
# message type, then CLIENTS bare participants that must discover all of them. Repeats ITERATIONS times and prints a
# verdict. Exit status is 1 if any client failed to discover every topic.
#
# Environment (all optional):
#   TYPES=300 CLIENTS=6 ITERATIONS=3 WAIT=20   workload size and how long a client may take (seconds)
#   ROS_DOMAIN_ID=100                          must be <= 232
#   FASTDDS_DEFAULT_PROFILES_FILE              Fast DDS XML profile (see profiles/)
#   MRE_DIAG=1                                 also report TypeLookup messages the (patched) library failed to send
source "${ROS_SETUP:-/opt/ros/lyrical/setup.bash}"
HERE=$(dirname "$(readlink -f "$0")")
TYPES=${TYPES:-300}; CLIENTS=${CLIENTS:-6}; ITERATIONS=${ITERATIONS:-3}; WAIT=${WAIT:-20}
export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-100}
WORK=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

echo "=== Fast DDS TypeLookup reproducer ==="
echo "library under test : $(python3 "$HERE/tl_mre.py" info 2>/dev/null)"
echo "workload           : 1 server with $TYPES topics (each a different message type) + $CLIENTS clients, $ITERATIONS iterations, up to ${WAIT}s per iteration"
echo "FASTDDS_DEFAULT_PROFILES_FILE = ${FASTDDS_DEFAULT_PROFILES_FILE:-<unset>}"
echo

bad=0
for i in $(seq 1 "$ITERATIONS"); do
  rm -f "$WORK/ready"
  python3 "$HERE/tl_mre.py" server "$TYPES" "$WORK/ready" > /dev/null 2> "$WORK/server_$i.err" & server=$!
  for _ in $(seq 1 100); do [ -f "$WORK/ready" ] && break; sleep 0.2; done
  [ -f "$WORK/ready" ] || { echo "server did not start"; exit 2; }
  pids=""
  for c in $(seq 1 "$CLIENTS"); do
    python3 "$HERE/tl_mre.py" client "$TYPES" "$WAIT" > "$WORK/client_${i}_$c.out" 2> "$WORK/client_${i}_$c.err" & pids="$pids $!"
  done
  wait $pids
  kill -INT $server 2>/dev/null; wait $server 2>/dev/null
  seen=$(cat "$WORK"/client_${i}_*.out | sed -E 's/RESULT seen=([0-9]+)\/.*/\1/' | tr '\n' ' ')
  stuck=$(cat "$WORK"/client_${i}_*.out | sed -E 's/RESULT seen=([0-9]+)\/.*/\1/' | awk -v t="$TYPES" '$1 < t {n++} END {print n+0}')
  printf "iteration %d: %d/%d clients are missing topics after %ss   (topics seen per client: %s of %d)\n" "$i" "$stuck" "$CLIENTS" "$WAIT" "$seen" "$TYPES"
  [ "$stuck" -gt 0 ] && bad=$((bad + 1))
  cat "$WORK"/server_$i.err "$WORK"/client_${i}_*.err >> "$WORK/all.err" 2>/dev/null
done

echo
if [ -n "${MRE_DIAG:-}" ]; then
  dropped=$(grep -c "fastdds-mre. TypeLookup message NOT SENT" "$WORK/all.err" 2>/dev/null)
  echo "TypeLookup messages Fast DDS failed to send (silently, without this patch): ${dropped:-0}"
  grep -m3 "fastdds-mre" "$WORK/all.err" | sed 's/^/    e.g. /'
  echo
fi
if [ "$bad" -gt 0 ]; then
  echo "=== RESULT: BUG REPRODUCED - in $bad of $ITERATIONS iterations clients were still missing topics after ${WAIT}s (they do not recover: the same is true at WAIT=90) ==="
  exit 1
fi
echo "=== RESULT: OK - every client discovered all $TYPES topics in all $ITERATIONS iterations ==="
