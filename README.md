# order-service (Kente Retail) — CI/CD

A small Spring Boot REST service, and the Jenkins pipeline that ships it without
a 2 a.m. release window.

This repo started as the Phase-1 fallback starter for the CI/CD module
("No More 2 A.M. Releases"): a working service and a **partially-working**
`Jenkinsfile` with three deliberate gaps. All three are closed. What is here now
is a pipeline that builds, tests, containerizes, scans, gates, and deploys
blue-green with a rollback — plus the Terraform and Jenkins configuration that
stands the whole thing up from nothing.

## Quick start

```bash
# 1. Provision two EC2 hosts (Jenkins + deploy target)
cd infra
terraform init
terraform apply \
  -var "admin_cidr=$(curl -s https://checkip.amazonaws.com)/32" \
  -var "jenkins_admin_password=<choose one>" \
  -var "slack_webhook_url=<optional>"
# Always pass admin_cidr on the command line. It is the one address allowed to
# reach SSH and Jenkins, and an ISP address changes without warning -- a stale
# value locks you out, and the symptom is a timeout rather than an error.

# 2. Hand the deploy key to Jenkins and start the controller
cd .. && ./scripts/bootstrap-jenkins.sh

# 3. Open the URL it prints, log in as admin, run the 'order-service' job

# 4. When you are done
./scripts/teardown.sh
```

## What is where

| Path | What it is |
|---|---|
| `Jenkinsfile` | The pipeline. Eight stages; the last four run on `main` only. |
| `deploy/bluegreen.sh` | The traffic switch, on the target. `status`/`deploy`/`switch`/`rollback`. |
| `deploy/smoke.sh` | Behavioural smoke test. Run against a colour port and through nginx. |
| `deploy/nginx/nginx.conf` | nginx on `:80`. The upstream file it includes is what a switch rewrites. |
| `infra/` | Terraform for both hosts, plus the Jenkins image, plugin list and JCasC config. |
| `scripts/` | Operator entry points: bootstrap, teardown, hardcoded-secret check, availability probe. |
| `docs/` | Executive summary, deployment-strategy memo, assumptions log, AI log, Jenkins setup, walkthrough, incident report, verified evidence. |

## How a release works

```
                     ┌─ main only ──────────────────────────────────┐
Checkout → Build → Test → Containerize → Security Scan → Approve → Deploy      → Switch  → Verify
                                              │                      (idle       (nginx
                                              │                       colour,     upstream
                                              │                       smoked      + smoke
                                         CRITICAL                     first)      via :80)
                                         fails here
```

The deploy target runs two containers at all times — `order-service-blue` on
`127.0.0.1:8081` and `order-service-green` on `127.0.0.1:8082` — with nginx on
`:80` pointing at exactly one of them. A release goes to whichever colour is
*not* live, gets smoke-tested there while still receiving no traffic, and only
then does the upstream file change and nginx reload. The previous colour keeps
running, so a rollback is a config reload rather than a redeploy:

```bash
ssh ec2-user@<target> sudo bluegreen.sh status     # which colour is live
ssh ec2-user@<target> sudo bluegreen.sh rollback   # put the previous one back
```

If a build fails *after* traffic has moved, the pipeline rolls back on its own.

## The three gaps, and what closed them

| Gap in the seeded pipeline | Fix |
|---|---|
| Trivy ran with `--exit-code 0 \|\| true` — reported findings, blocked nothing | Two passes: everything reported and archived, `CRITICAL` alone as a hard gate with no swallowed exit code |
| `sshpass -p '<literal>'` — the password was in the file, in git, and in every build log | `sshagent(credentials: ['kente-deploy-ssh'])`, declared in JCasC, referenced by id only |
| `docker rm -f` then `docker run` — an outage on every release, nothing to go back to | Blue-green with an nginx switch, pre-switch smoke test, and automatic rollback |

`scripts/check-no-hardcoded-secrets.sh` runs on every build so the second one
stays closed.

## Branches that are supposed to fail

Evidence for two acceptance criteria, as real red builds rather than screenshots:

| Branch | Fails at | Why |
|---|---|---|
| `broken/order-id-collision` | `Test` | Sequence starts inside the fixture range, so a generated ID collides with `ORD-1001` |
| `broken/vulnerable-dependency` | `Security Scan` | Ships a Log4j version with a fixed `CRITICAL` CVE |

## Running the service locally

```bash
mvn spring-boot:run
./deploy/smoke.sh http://127.0.0.1:8080
```
