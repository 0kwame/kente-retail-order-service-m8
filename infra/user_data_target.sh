#!/bin/bash
# Deploy-target boot. Deliberately thin: install what is needed to clone the
# repo, then hand off to the bootstrap script that lives IN the repo, so nginx
# config and bluegreen.sh have exactly one source of truth. Re-running the
# bootstrap after a `git pull` applies changes without rebuilding the instance.
set -eux

dnf install -y docker git nginx
systemctl enable --now docker

git clone --branch ${repo_branch} --depth 1 ${repo_url} /opt/kente-repo
bash /opt/kente-repo/infra/target-host/bootstrap.sh
