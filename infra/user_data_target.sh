#!/bin/bash
# Deploy-target boot. Deliberately thin: install what is needed to clone the
# repo, then hand off to the bootstrap script that lives IN the repo, so nginx
# config and bluegreen.sh have exactly one source of truth. Re-running the
# bootstrap after a `git pull` applies changes without rebuilding the instance.
set -eux

dnf install -y docker git nginx
systemctl enable --now docker

# Where bluegreen.sh finds the DB password. A secret NAME, not a value: the
# value is read from Secrets Manager with the instance role at deploy time.
cat > /etc/kente-target.env <<'KENTE_ENV_EOF'
AWS_REGION=${region}
DB_SECRET_ID=${db_secret_id}
KENTE_ENV_EOF
chmod 644 /etc/kente-target.env

git clone --branch ${repo_branch} --depth 1 ${repo_url} /opt/kente-repo
bash /opt/kente-repo/infra/target-host/bootstrap.sh
