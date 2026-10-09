#!/usr/bin/env bash
#
# Load the supplied incident logs into CloudWatch so the investigation query can
# run against them.
#
#   ./scripts/load-sample-logs.sh [access-log] [app-log]
#
# CloudWatch rejects events older than 14 days, and the samples are from
# 2026-07-16. So each event gets the CURRENT time as its CloudWatch timestamp,
# and the line is stored unchanged, original timestamp included. The query reads
# the original time from the message, not from the CloudWatch timestamp.
#
# Runs from your machine with your own AWS credentials. Needs python3 and the
# aws CLI. Safe to run again: the streams are deleted and recreated.

set -euo pipefail

cd "$(dirname "$0")/.."

GROUP=/kente/order-service/incident-2026-07-16
ACCESS=${1:-../sample-logs/kente-order-service-access.log}
APP=${2:-../sample-logs/kente-order-service-app.log}
REGION=$(terraform -chdir=infra output -raw region)

load() {  # load <file> <stream>
    local file=$1 stream=$2 events
    [[ -f $file ]] || { echo "load-sample-logs: $file not found" >&2; exit 1; }
    aws logs delete-log-stream --region "$REGION" --log-group-name "$GROUP" --log-stream-name "$stream" 2>/dev/null || true
    aws logs create-log-stream --region "$REGION" --log-group-name "$GROUP" --log-stream-name "$stream"
    # One millisecond apart keeps the original order. Blank lines are skipped.
    events=$(python3 -c '
import json, sys, time
now = int(time.time() * 1000)
lines = [l.rstrip("\n") for l in open(sys.argv[1]) if l.strip()]
print(json.dumps([{"timestamp": now + i, "message": m} for i, m in enumerate(lines)]))
' "$file")
    aws logs put-log-events --region "$REGION" --log-group-name "$GROUP" \
        --log-stream-name "$stream" --log-events "$events" >/dev/null
    echo "load-sample-logs: $(grep -c . "$file") lines from $(basename "$file") -> $GROUP:$stream"
}

load "$ACCESS" access
load "$APP" app
