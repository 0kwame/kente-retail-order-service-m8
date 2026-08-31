#!/usr/bin/env bash
#
# Configure the deploy target. Idempotent -- re-run after `git -C /opt/kente-repo pull`
# to pick up changes to nginx.conf or bluegreen.sh.
#
#   sudo bash /opt/kente-repo/infra/target/bootstrap.sh

set -euo pipefail

REPO_DIR=${REPO_DIR:-/opt/kente-repo}
UPSTREAM_CONF=/etc/nginx/conf.d/upstream-order-service.conf

log() { echo "target-bootstrap: $*"; }

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# --- the deploy user the pipeline SSHes in as -------------------------------
if ! id deploy &>/dev/null; then
    log "creating deploy user"
    useradd --create-home --shell /bin/bash deploy
fi
usermod -aG docker deploy

install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# Same public key Terraform put on ec2-user. One keypair for the lab; the
# private half lives in the Jenkins credential store and on the operator's box.
install -m 600 -o deploy -g deploy /home/ec2-user/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys

# --- privileged commands, narrowly ------------------------------------------
# deploy may run exactly one root command. The script is root-owned and not
# writable by deploy, so this is not a path to a root shell.
install -m 755 -o root -g root "$REPO_DIR/deploy/bluegreen.sh" /usr/local/bin/bluegreen.sh
install -m 755 -o root -g root "$REPO_DIR/deploy/smoke.sh"     /usr/local/bin/smoke.sh

cat > /etc/sudoers.d/kente-deploy <<'SUDO'
# The deploy user's entire privileged surface: one root-owned script.
deploy ALL=(root) NOPASSWD: /usr/local/bin/bluegreen.sh
SUDO
chmod 440 /etc/sudoers.d/kente-deploy
visudo -cf /etc/sudoers.d/kente-deploy

# --- nginx: the traffic switch ----------------------------------------------
install -m 644 -o root -g root "$REPO_DIR/deploy/nginx/nginx.conf" /etc/nginx/nginx.conf

# Only seed the upstream if it does not exist -- re-running bootstrap must not
# silently move production traffic to the other colour.
if [[ ! -f "$UPSTREAM_CONF" ]]; then
    log "seeding upstream at blue (no container yet -- :80 returns 502 until the first deploy)"
    cat > "$UPSTREAM_CONF" <<'SEED'
# live: blue
# Seeded by target/bootstrap.sh -- bluegreen.sh owns this file from here on.
upstream order_service_backend {
    server 127.0.0.1:8081;
}
SEED
else
    log "upstream already exists, live colour left as: $(sed -n 's/^# live: //p' "$UPSTREAM_CONF" | head -1)"
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx || systemctl restart nginx

log "ready. live colour: $(/usr/local/bin/bluegreen.sh current)"
