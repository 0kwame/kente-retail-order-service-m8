#!/usr/bin/env bash
#
# Fill the Secrets Manager secrets that Terraform created empty. This is the
# only place a secret value is produced or typed, and it goes straight from this
# script to Secrets Manager over stdin: not a command-line argument (visible in
# `ps`), not a file, not Terraform state.
#
#   ./scripts/set-secrets.sh              # fill any secret that has no value yet
#                                         # (asks for the Jenkins password and the
#                                         # optional Slack webhook the first time)
#   ./scripts/set-secrets.sh --rotate-db  # new DB password (then redeploy)
#
# Idempotent: a secret that already has a value is left alone unless you ask
# for a rotation.

set -euo pipefail

cd "$(dirname "$0")/../infra"

ROTATE_DB=0
[[ ${1:-} == --rotate-db ]] && ROTATE_DB=1

REGION=$(terraform output -raw region)
DB_SECRET_ID=$(terraform output -raw db_secret_id)
ADMIN_SECRET_ID=$(terraform output -raw jenkins_admin_secret_id)
WEBHOOK_SECRET_ID=$(terraform output -raw slack_webhook_secret_id)
GRAFANA_SECRET_ID=$(terraform output -raw grafana_secret_id)

log() { echo "set-secrets: $*"; }

has_value() {
    aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" \
        --query VersionId --output text >/dev/null 2>&1
}

# Value on stdin only.
put() {
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" \
        --secret-string file:///dev/stdin >/dev/null
    log "$1 set"
}

# The DB password is generated, never chosen. Nobody needs to know it: the
# service reads it at deploy time. The value that leaked in the near-miss is
# never reused; a fresh one is the rotation.
if (( ROTATE_DB )) || ! has_value "$DB_SECRET_ID"; then
    openssl rand -base64 32 | tr -d '\n' | put "$DB_SECRET_ID"
    if (( ROTATE_DB )); then
        log "rotated. Redeploy (run the pipeline) so the service picks up the new value."
    fi
else
    log "$DB_SECRET_ID already has a value (use --rotate-db to replace it)"
fi

# Typed, not echoed, and never in shell history.
if has_value "$ADMIN_SECRET_ID"; then
    log "$ADMIN_SECRET_ID already has a value"
else
    read -r -s -p "Jenkins admin password: " pw; echo
    [[ ${#pw} -ge 12 ]] || { echo "set-secrets: use at least 12 characters" >&2; exit 1; }
    printf '%s' "$pw" | put "$ADMIN_SECRET_ID"
    unset pw
fi

if has_value "$WEBHOOK_SECRET_ID"; then
    log "$WEBHOOK_SECRET_ID already has a value"
else
    read -r -s -p "Slack webhook URL (Enter for none): " hook; echo
    printf '%s' "${hook:-none}" | put "$WEBHOOK_SECRET_ID"
    unset hook
fi

# Generated like the DB password, nobody needs to know it. Read it when you log
# in to Grafana: aws secretsmanager get-secret-value --secret-id <grafana_secret_id>
# Hex, not base64, because start.sh writes it to an env file.
if has_value "$GRAFANA_SECRET_ID"; then
    log "$GRAFANA_SECRET_ID already has a value"
else
    openssl rand -hex 16 | put "$GRAFANA_SECRET_ID"
fi
