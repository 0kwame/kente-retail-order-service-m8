#!/usr/bin/env bash
#
# Fails if a credential is typed into a tracked file instead of coming from the
# Jenkins credential store.
#
# The seeded Jenkinsfile authenticated with a password written straight into the
# pipeline. Deleting that line once is not the same as it staying deleted, so
# the pipeline runs this on every build. Cheap, and it fails loudly.
#
#   ./scripts/check-no-hardcoded-secrets.sh [path ...]

set -euo pipefail

PATHS=("${@:-Jenkinsfile deploy infra scripts}")

# Written as fragments so this file does not itself contain a literal that its
# own pattern would match.
PATTERNS=(
    'sshpass[[:space:]]+-p'
    'ChangeMe'
    'BEGIN[[:space:]]+(RSA|OPENSSH|EC)[[:space:]]+PRIVATE[[:space:]]+KEY'
    '(password|passwd|secret|token)[[:space:]]*=[[:space:]]*.[A-Za-z0-9!@#$%^&*_-]{6,}.'
)

status=0
for pattern in "${PATTERNS[@]}"; do
    # -I skips binaries; the script excludes itself, since it holds the patterns.
    if hits=$(grep -rInE --exclude="$(basename "$0")" "$pattern" ${PATHS[*]} 2>/dev/null); then
        echo "hardcoded-secret check FAILED on pattern: $pattern" >&2
        echo "$hits" >&2
        status=1
    fi
done

if (( status )); then
    echo >&2
    echo "Move the value into a Jenkins credential and reference it by credentialsId." >&2
    exit 1
fi

echo "hardcoded-secret check passed: no credential literals in ${PATHS[*]}"
