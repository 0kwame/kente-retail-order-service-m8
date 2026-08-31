#!/usr/bin/env bash
#
# Blue-green control for Kente Retail order-service, on the deploy target.
#
# Two containers, two ports, one nginx upstream file. The upstream file IS the
# state -- whichever colour it names is the colour serving port 80. A switch is
# a file rewrite plus `nginx -s reload`; a rollback is the same thing pointed
# back. Neither one stops the container that was already serving, which is why
# a rollback costs a reload instead of a redeploy.
#
# Installed root-owned at /usr/local/bin/bluegreen.sh by infra/user_data_target.sh.
# The deploy user is granted exactly this one command via sudoers.
#
# ponytail: state lives in a conf file and there is one target host. Move to a
# real service registry (or an ALB with two target groups) only if the deploy
# target ever becomes more than one box.

set -euo pipefail

BLUE_PORT=8081
GREEN_PORT=8082
UPSTREAM_CONF=/etc/nginx/conf.d/upstream-order-service.conf
CONTAINER_PREFIX=order-service
HEALTH_PATH=/health
HEALTH_RETRIES=30
HEALTH_INTERVAL=2

die() { echo "bluegreen: $*" >&2; exit 1; }
log() { echo "bluegreen: $*"; }

port_for() {
    case "$1" in
        blue)  echo "$BLUE_PORT" ;;
        green) echo "$GREEN_PORT" ;;
        *)     die "unknown colour '$1' (expected blue or green)" ;;
    esac
}

other_colour() {
    case "$1" in
        blue)  echo green ;;
        green) echo blue ;;
        *)     die "unknown colour '$1'" ;;
    esac
}

# The one source of truth for who is live.
current_colour() {
    [[ -f "$UPSTREAM_CONF" ]] || die "$UPSTREAM_CONF missing -- target not bootstrapped"
    local colour
    colour=$(sed -n 's/^# live: \(blue\|green\)$/\1/p' "$UPSTREAM_CONF" | head -1)
    [[ -n "$colour" ]] || die "cannot read live colour from $UPSTREAM_CONF"
    echo "$colour"
}

write_upstream() {
    local colour=$1 port
    port=$(port_for "$colour")
    cat > "$UPSTREAM_CONF" <<EOF
# live: $colour
# Written by bluegreen.sh at $(date -u +%Y-%m-%dT%H:%M:%SZ) -- do not hand-edit.
upstream order_service_backend {
    server 127.0.0.1:$port;
}
EOF
}

wait_healthy() {
    local url=$1 i
    for ((i = 1; i <= HEALTH_RETRIES; i++)); do
        if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
            log "healthy: $url (after ${i} attempt(s))"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
    done
    die "never became healthy: $url (gave up after $((HEALTH_RETRIES * HEALTH_INTERVAL))s)"
}

cmd_current() { current_colour; }

cmd_idle() { other_colour "$(current_colour)"; }

cmd_status() {
    local live idle
    live=$(current_colour)
    idle=$(other_colour "$live")
    echo "live colour   : $live  (port $(port_for "$live"))"
    echo "idle colour   : $idle  (port $(port_for "$idle"))"
    echo "upstream conf : $UPSTREAM_CONF"
    echo
    echo "containers:"
    docker ps -a --filter "name=${CONTAINER_PREFIX}-" \
        --format '  {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
    echo
    for colour in blue green; do
        local port code
        port=$(port_for "$colour")
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://127.0.0.1:${port}${HEALTH_PATH}" 2>/dev/null || echo "---")
        echo "  ${colour} direct  http://127.0.0.1:${port}${HEALTH_PATH} -> ${code}"
    done
    local code80
    code80=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        "http://127.0.0.1${HEALTH_PATH}" 2>/dev/null || echo "---")
    echo "  via nginx    http://127.0.0.1${HEALTH_PATH} -> ${code80}"
}

# Start an image on one colour's port. Does not touch traffic.
cmd_deploy() {
    local colour=${1:-} image=${2:-} port name
    [[ -n "$colour" && -n "$image" ]] || die "usage: bluegreen.sh deploy <blue|green> <image>"
    port=$(port_for "$colour")
    name="${CONTAINER_PREFIX}-${colour}"

    docker image inspect "$image" >/dev/null 2>&1 || die "image not present on target: $image"

    if [[ "$colour" == "$(current_colour)" ]]; then
        die "refusing to deploy onto the live colour ($colour) -- that is the not-blue-green path the brief rules out"
    fi

    log "replacing container $name with $image on port $port"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        -p "127.0.0.1:${port}:8080" \
        --label "kente.colour=${colour}" \
        --label "kente.image=${image}" \
        "$image" >/dev/null

    wait_healthy "http://127.0.0.1:${port}${HEALTH_PATH}"
    log "deployed $image to $colour, not yet receiving traffic"
}

cmd_switch() {
    local target=${1:-} live port
    [[ -n "$target" ]] || die "usage: bluegreen.sh switch <blue|green>"
    port=$(port_for "$target")
    live=$(current_colour)

    if [[ "$target" == "$live" ]]; then
        log "$target is already live -- nothing to switch"
        return 0
    fi

    # Never move traffic to something that isn't answering.
    wait_healthy "http://127.0.0.1:${port}${HEALTH_PATH}"

    local backup
    backup=$(mktemp)
    cp "$UPSTREAM_CONF" "$backup"

    write_upstream "$target"
    if ! nginx -t 2>/dev/null; then
        cp "$backup" "$UPSTREAM_CONF"
        rm -f "$backup"
        die "nginx rejected the new upstream conf -- reverted, traffic untouched"
    fi
    nginx -s reload
    rm -f "$backup"

    wait_healthy "http://127.0.0.1${HEALTH_PATH}"
    log "traffic switched: $live -> $target (previous colour left running for rollback)"
}

cmd_rollback() {
    local live previous
    live=$(current_colour)
    previous=$(other_colour "$live")
    local port
    port=$(port_for "$previous")

    docker ps --filter "name=${CONTAINER_PREFIX}-${previous}" --filter status=running -q \
        | grep -q . || die "cannot roll back: no running container on $previous"

    log "rolling back: $live -> $previous"
    cmd_switch "$previous"
    log "rollback complete, $previous is live"
}

main() {
    local cmd=${1:-status}
    shift || true
    case "$cmd" in
        status)   cmd_status ;;
        current)  cmd_current ;;
        idle)     cmd_idle ;;
        deploy)   cmd_deploy "$@" ;;
        switch)   cmd_switch "$@" ;;
        rollback) cmd_rollback ;;
        *)        die "usage: bluegreen.sh {status|current|idle|deploy <colour> <image>|switch <colour>|rollback}" ;;
    esac
}

main "$@"
