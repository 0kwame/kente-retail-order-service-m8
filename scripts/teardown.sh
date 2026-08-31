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

terraform destroy -auto-approve
rm -f ./kente-cicd-key.pem
echo "teardown: done. Nothing left running."
