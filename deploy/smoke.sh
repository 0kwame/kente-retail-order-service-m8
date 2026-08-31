#!/usr/bin/env bash
#
# Smoke test for a running order-service, against any base URL.
#
# The pipeline runs this twice: once against the idle colour's port before any
# traffic moves (so a bad build never reaches a customer), and once through
# nginx on :80 after the switch (so a bad switch is caught immediately).
#
# Deliberately asserts behaviour, not just liveness -- a 200 from /health only
# proves the JVM booted, which is not the same as the service working.

set -euo pipefail

BASE=${1:-http://127.0.0.1}
FAILED=0

check() {
    local label=$1 
    shift
    if "$@"; then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label"
        FAILED=1
    fi
}

health_is_ok() {
    [[ "$(curl -fsS --max-time 5 "${BASE}/health")" == "OK" ]]
}

lists_both_fixtures() {
    local body
    body=$(curl -fsS --max-time 5 "${BASE}/api/orders")
    grep -q 'ORD-1001' <<<"$body" && grep -q 'ORD-1002' <<<"$body"
}

creates_an_order_outside_the_fixture_range() {
    local body id
    body=$(curl -fsS --max-time 5 -X POST "${BASE}/api/orders" \
        -H 'Content-Type: application/json' \
        -d '{"item":"kente-cloth-wrap","quantity":2}')
    id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<<"$body")
    [[ -n "$id" ]] || return 1
    # The defect this guards against hands back ORD-1001, colliding with a fixture.
    [[ "$id" != "ORD-1001" && "$id" != "ORD-1002" ]]
}

echo "smoke: ${BASE}"
check "GET /health returns OK"                        health_is_ok
check "GET /api/orders lists ORD-1001 and ORD-1002"   lists_both_fixtures
check "POST /api/orders returns a non-fixture ID"     creates_an_order_outside_the_fixture_range

if (( FAILED )); then
    echo "smoke: FAILED against ${BASE}" >&2
    exit 1
fi
echo "smoke: all checks passed against ${BASE}"
