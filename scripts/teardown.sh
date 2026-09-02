#!/usr/bin/env bash
#
# Destroy the lab. The whole point of Terraform here is that the cost stops
# when the walkthrough does.
#
#   ./scripts/teardown.sh

set -euo pipefail

cd "$(dirname "$0")/../infra"

echo "This destroys the Jenkins host, the deploy target, the keypair and the security groups."
echo "Build history and the failed-build evidence live on the Jenkins volume and go with it --"
echo "export anything you still need for the submission first (docs/walkthrough.md says how)."
read -r -p "Type 'destroy' to continue: " reply
[[ $reply == "destroy" ]] || { echo "aborted"; exit 1; }

# admin_cidr is not stored in terraform.tfvars on purpose (it goes stale), but
# `destroy` still requires every variable to be set even though it uses none of
# them. A placeholder keeps teardown working with no network lookup, which
# matters: teardown must not be the thing that fails when you are trying to stop
# paying for something.
terraform destroy -auto-approve -var "admin_cidr=127.0.0.1/32"
rm -f ./kente-cicd-key.pem
echo "teardown: done. Nothing left running."
