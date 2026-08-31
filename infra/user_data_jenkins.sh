#!/bin/bash
# Jenkins-host boot. Installs Docker and clones the repo, then STOPS.
#
# Jenkins itself is started by scripts/bootstrap-jenkins.sh from the operator's
# machine, because the deploy private key has to arrive before JCasC runs and
# the one place that key must never live is user_data -- anything that can read
# the instance metadata service can read user_data.
set -eux

dnf install -y docker git
systemctl enable --now docker

umask 077
cat > /etc/kente-jenkins.env <<'KENTE_ENV_EOF'
JENKINS_ADMIN_PASSWORD=${jenkins_admin_password}
SLACK_WEBHOOK_URL=${slack_webhook_url}
DEPLOY_HOST=${deploy_host}
REPO_URL=${repo_url}
REPO_BRANCH=${repo_branch}
KENTE_ENV_EOF
chmod 600 /etc/kente-jenkins.env

git clone --branch ${repo_branch} --depth 1 ${repo_url} /opt/kente-repo
mkdir -p /etc/kente-secrets
chmod 700 /etc/kente-secrets

touch /var/log/kente-user-data-done
