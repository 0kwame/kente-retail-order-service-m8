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
#
# WHERE YOU RUN THIS CHANGES WHAT IT MEASURES. From a laptop it measures your
# home connection as well as the service, and a couple of 2-second timeouts from
# ordinary packet loss look exactly like dropped requests. That happened while
# verifying this pipeline: two failures 16 seconds AFTER the switch had already
# completed.
#
# The target's own log is the arbiter -- if a request is not in it, it never
# arrived and the loss was upstream of AWS:
#
#   ssh ec2-user@<target> 'sudo tail -40 /var/log/nginx/access.log'
#
# For a number you can defend, run this ON the Jenkins host against the target's
# PRIVATE ip, which takes the internet out of the measurement entirely.

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
