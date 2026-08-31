#!/usr/bin/env bash
#
# Poll the service through nginx and report whether anything was dropped.
#
# This is the zero-downtime evidence. Run it in one terminal, do a release or a
# rollback in another, then stop it with Ctrl-C: it prints how many samples it
# took and how many were not 200. "Zero downtime" should mean a number, not an
# adjective.
#
#   ./scripts/availability-probe.sh http://<target>
#   ./scripts/availability-probe.sh http://<target> 0.1     # tighter interval

set -uo pipefail

BASE=${1:?usage: availability-probe.sh <base-url> [interval-seconds]}
INTERVAL=${2:-0.2}
LOG=$(mktemp -t availability-XXXXXX.log)

report() {
    local total bad
    total=$(wc -l < "$LOG" | tr -d ' ')
    bad=$(grep -cv ' 200$' "$LOG" || true)
    echo
    echo "probe: ${total} samples over ${BASE}${HEALTH:-/health}, interval ${INTERVAL}s"
    echo "probe: non-200 responses: ${bad}"
    if [[ "$bad" != "0" ]]; then
        echo "probe: the failures were:"
        grep -v ' 200$' "$LOG" | head -20
    fi
    echo "probe: full log at $LOG"
    exit 0
}
trap report INT TERM

echo "probe: polling ${BASE}/health every ${INTERVAL}s. Ctrl-C to stop and report."
while true; do
    printf '%s %s\n' \
        "$(date -u +%H:%M:%S.%2N)" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${BASE}/health" || echo ERR)" \
        | tee -a "$LOG"
    sleep "$INTERVAL"
done
