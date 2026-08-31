#!/usr/bin/env bash
#
# Build and (re)start the Jenkins controller. Idempotent -- re-run after
# `git -C /opt/kente-repo pull` to apply a config or plugin change:
#
#   sudo bash /opt/kente-repo/infra/jenkins/bootstrap.sh
#
# Jenkins home is a named volume, so job history and build logs survive a
# rebuild. That matters here: the failed builds ARE the deliverable evidence.

set -euo pipefail

REPO_DIR=${REPO_DIR:-/opt/kente-repo}
ENV_FILE=${ENV_FILE:-/etc/kente-jenkins.env}
SECRETS_DIR=${SECRETS_DIR:-/etc/kente-secrets}
IMAGE=kente-jenkins:local
CONTAINER=jenkins

log() { echo "jenkins-bootstrap: $*"; }
die() { echo "jenkins-bootstrap: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -f $ENV_FILE ]] || die "$ENV_FILE missing -- was this host created by Terraform?"

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

[[ -n ${JENKINS_ADMIN_PASSWORD:-} ]] || die "JENKINS_ADMIN_PASSWORD empty in $ENV_FILE"
[[ -n ${DEPLOY_HOST:-} ]]            || die "DEPLOY_HOST empty in $ENV_FILE"
[[ -f $SECRETS_DIR/kente_deploy_key ]] || die \
    "$SECRETS_DIR/kente_deploy_key missing -- run scripts/bootstrap-jenkins.sh from your machine, which copies it here"

# The jenkins user inside the container is uid 1000 and must read the key.
chown 1000:1000 "$SECRETS_DIR/kente_deploy_key"
chmod 600 "$SECRETS_DIR/kente_deploy_key"
chmod 755 "$SECRETS_DIR"

log "building $IMAGE"
docker build -t "$IMAGE" "$REPO_DIR/infra/jenkins"

# Give the container the host's docker group so the mounted socket is usable
# without running Jenkins as root.
DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)
log "host docker gid: $DOCKER_GID"

log "restarting $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    -p 8080:8080 \
    --group-add "$DOCKER_GID" \
    -v jenkins_home:/var/jenkins_home \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$REPO_DIR/infra/jenkins/jenkins.yaml":/var/jenkins_home/casc/jenkins.yaml:ro \
    -v "$SECRETS_DIR":/run/secrets:ro \
    -e CASC_JENKINS_CONFIG=/var/jenkins_home/casc/jenkins.yaml \
    -e JENKINS_ADMIN_PASSWORD \
    -e SLACK_WEBHOOK_URL \
    -e DEPLOY_HOST \
    -e REPO_URL \
    -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.model.DownloadService.noSignatureCheck=true" \
    "$IMAGE" >/dev/null

log "waiting for Jenkins to answer"
for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:8080/login"; then
        log "Jenkins is up after ${i}0s or less"
        exit 0
    fi
    sleep 5
done

echo "--- last 60 lines of container log ---" >&2
docker logs --tail 60 "$CONTAINER" >&2 || true
die "Jenkins did not come up within 5 minutes"
