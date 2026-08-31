#!/usr/bin/env bash
#
# Finish the Jenkins install after `terraform apply`.
#
# This is the one step that cannot live in user_data: it hands the deploy
# private key to the Jenkins host over SSH (stdin -> sudo tee, so the key never
# lands in /tmp or in shell history) and only then starts the controller, so
# JCasC finds the credential it needs on its first load.
#
#   ./scripts/bootstrap-jenkins.sh
#
# Idempotent. Re-run it after changing jenkins.yaml, plugins.txt or the
# Dockerfile -- it pulls the repo on the host and rebuilds.

set -euo pipefail

cd "$(dirname "$0")/../infra"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

need_output() {
    terraform output -raw "$1" 2>/dev/null || {
        echo "bootstrap: terraform output '$1' is missing -- run terraform apply first" >&2
        exit 1
    }
}

JENKINS_IP=$(need_output jenkins_public_ip)
TARGET_IP=$(need_output target_public_ip)
PEM=$(need_output private_key_path)
REPO_BRANCH=${REPO_BRANCH:-main}

[[ -f $PEM ]] || { echo "bootstrap: key file $PEM not found" >&2; exit 1; }
chmod 600 "$PEM"

log() { echo "bootstrap: $*"; }

wait_for_ssh() {
    local ip=$1 name=$2 i
    log "waiting for SSH on $name ($ip)"
    for ((i = 1; i <= 60; i++)); do
        if ssh "${SSH_OPTS[@]}" -i "$PEM" "ec2-user@$ip" true 2>/dev/null; then
            log "$name reachable"
            return 0
        fi
        sleep 5
    done
    echo "bootstrap: $name never became reachable" >&2
    exit 1
}

wait_for_cloud_init() {
    local ip=$1 name=$2 i
    log "waiting for cloud-init on $name"
    for ((i = 1; i <= 90; i++)); do
        if ssh "${SSH_OPTS[@]}" -i "$PEM" "ec2-user@$ip" \
            'sudo cloud-init status --wait >/dev/null 2>&1 || true; test -d /opt/kente-repo' 2>/dev/null; then
            log "$name bootstrapped"
            return 0
        fi
        sleep 10
    done
    echo "bootstrap: cloud-init on $name did not finish. Check: sudo tail -50 /var/log/cloud-init-output.log" >&2
    exit 1
}

wait_for_ssh "$TARGET_IP" deploy-target
wait_for_cloud_init "$TARGET_IP" deploy-target

wait_for_ssh "$JENKINS_IP" jenkins-host
wait_for_cloud_init "$JENKINS_IP" jenkins-host

# --- hand over the deploy key ----------------------------------------------
log "installing the deploy key on the Jenkins host (via stdin, not a temp file)"
ssh "${SSH_OPTS[@]}" -i "$PEM" "ec2-user@$JENKINS_IP" \
    'sudo install -d -m 755 /etc/kente-secrets && sudo tee /etc/kente-secrets/kente_deploy_key >/dev/null && sudo chmod 600 /etc/kente-secrets/kente_deploy_key' \
    < "$PEM"

# --- start Jenkins ----------------------------------------------------------
log "pulling repo and starting Jenkins (first run builds the image -- a few minutes)"
ssh "${SSH_OPTS[@]}" -i "$PEM" "ec2-user@$JENKINS_IP" \
    "sudo git -C /opt/kente-repo fetch --depth 1 origin ${REPO_BRANCH} && sudo git -C /opt/kente-repo reset --hard FETCH_HEAD && sudo bash /opt/kente-repo/infra/jenkins/bootstrap.sh"

echo
log "done."
echo "  Jenkins   : http://${JENKINS_IP}:8080   (user: admin)"
echo "  Service   : http://${TARGET_IP}         (502 until the first pipeline deploy)"
echo "  SSH target: ssh -i ${PEM} ec2-user@${TARGET_IP}"
