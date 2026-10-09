#!/usr/bin/env bash
#
# Start (or update) Prometheus, Alertmanager and Grafana on the deploy target.
# Run as root by infra/target-host/bootstrap.sh. Safe to run again.
#
# The two secrets are read from Secrets Manager with the instance role and go
# to root-only files under /etc/kente-monitoring. They are not in git, in the
# images or in Terraform state.

set -euo pipefail

cd "$(dirname "$0")"

# AWS_REGION, SLACK_SECRET_ID and GRAFANA_SECRET_ID, written by user_data_target.sh.
# shellcheck disable=SC1091
source /etc/kente-target.env

export KENTE_STATE_DIR=/etc/kente-monitoring
install -d -m 700 "$KENTE_STATE_DIR"

secret() {
    aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$1" \
        --query SecretString --output text \
        || { echo "start: cannot read secret $1 -- run scripts/set-secrets.sh" >&2; exit 1; }
}

# The Slack secret holds "none" when there is no webhook. Alertmanager still
# runs, but with a receiver that sends nothing.
hook=$(secret "$SLACK_SECRET_ID")
if [[ $hook == none ]]; then
    install -m 644 alertmanager-no-slack.yml "$KENTE_STATE_DIR/alertmanager.yml"
    : > "$KENTE_STATE_DIR/slack_webhook"
else
    install -m 644 alertmanager.yml "$KENTE_STATE_DIR/alertmanager.yml"
    printf '%s' "$hook" > "$KENTE_STATE_DIR/slack_webhook"
fi
unset hook
# The Alertmanager image runs as nobody (65534). Owner read-only.
chown 65534:65534 "$KENTE_STATE_DIR/slack_webhook"
chmod 400 "$KENTE_STATE_DIR/slack_webhook"

( umask 077; printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$(secret "$GRAFANA_SECRET_ID")" > "$KENTE_STATE_DIR/env" )

docker compose --env-file "$KENTE_STATE_DIR/env" up -d --remove-orphans
echo "start: monitoring is up. Grafana on :3000 for admin_cidr only."
