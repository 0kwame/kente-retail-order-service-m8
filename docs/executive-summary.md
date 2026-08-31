# Executive Summary — order-service CI/CD

**Client:** Kente Retail · **Engagement:** "No More 2 A.M. Releases" · **Prepared by:** Joseph Akayesi

---

## What you asked for

A pipeline a junior engineer can run with confidence on a Friday afternoon: one
that stops a bad change before production, scans for known vulnerabilities before
they ship, and does not take the site down on the way to a deploy.

## What now exists

An eight-stage Jenkins pipeline that takes a commit to a live, running service
without a maintenance window, and refuses to do so when the change is unsafe.

- **Bad changes stop at test.** A regression that would have shipped a colliding
  order ID is blocked by an automated test, on a real failed build. The starter
  repo had a placeholder test in that exact position that asserted nothing.
- **Known vulnerabilities stop the release.** Trivy scans every image; a CRITICAL
  finding with an available fix fails the build. This is not theoretical — see
  below.
- **Deploys no longer cause an outage.** Two copies of the service run at all
  times. A release goes to the copy not serving customers, is health- and
  behaviour-tested there, and only then does traffic move. The switch is a
  configuration reload of about a second, with no window where nothing is
  listening. Today's process stops the running container before starting the new
  one, so every release is a deliberate outage.
- **Going back is a second, not a rebuild.** The previous version keeps running
  after a release, so a rollback is the same one-second switch pointed backwards.
  If a build fails after traffic has moved, the pipeline rolls back on its own.
- **No credentials in the pipeline.** The starter authenticated with a password
  typed into the pipeline file — visible in the repository, in its history, and in
  every build log. It is now an SSH key held in Jenkins' credential store, and an
  automated check on every build fails if a credential literal reappears.
- **One human decision, in the right place.** A single approval gate sits
  immediately before traffic moves — after the new version is already running and
  tested, so the question being asked is "shall this go live?" with evidence in
  hand. Everything before it runs unattended.

## The pipeline found a real vulnerability on its first run

Before it had scanned anything of ours, the new gate failed the build on **four
CRITICAL CVEs in the Tomcat server bundled with Spring Boot 3.2.5**, including a
remote-code-execution issue and an authentication bypass. All four had published
fixes. None came from Kente Retail's code — they arrived with the framework and
had been in the running image since this service was built. Nothing was looking,
so nothing found them.

Patched by pinning Tomcat to 10.1.59, deliberately chosen over a full framework
upgrade: a patch release is a far smaller risk three weeks before Kente Fest. The
build is now clean.

**This is the return on the work.** The pipeline paid for itself before its first
deployment.

## Deployment strategy: blue-green, not canary

Blue-green was chosen and implemented. Canary detects problems slightly earlier by
exposing a small slice of customers to a new version; blue-green reverses a bad
release completely, in about a second. For a single stateless service on one host,
during the highest-revenue week of the year, the ability to be **fully back to
normal immediately** is worth more than earlier detection — particularly since
canary's advantage depends on per-version monitoring Kente Retail does not have
yet. Full comparison in `docs/deployment-strategy-memo.md`.

## Cost

| Item | Cost |
|---|---|
| Jenkins host + deploy target (2 × t3.small, us-east-1) | ~$0.042/hour, ~$30/month if left running |
| Container registry | $0 — images ship over the existing SSH connection |
| Load balancer | $0 — nginx on the target does the traffic switch |
| **New spend beyond prior modules** | **Two small instances, and nothing else** |

Everything is Terraform, so the environment can be destroyed and recreated on
demand; `scripts/teardown.sh` stops the meter in one command.

## Risks and what I would do next, in priority order

1. **Database migrations are the real gap.** This service is stateless, which is
   what makes blue-green nearly free. The moment order-service owns a schema, both
   colours share one database and every release needs migrations that are
   backward-compatible with the version still running — otherwise the rollback is
   a promise that will not hold. **This is the next piece of work**, and it is
   bigger than this pipeline was.
2. **The approval gate needs an owner.** A gate nobody is available to click
   out-of-hours is a new way to be woken at 2 a.m. Needs an on-call rota, or
   automatic approval outside a change-freeze window.
3. **Some regressions will still reach everyone.** A slow memory leak or a query
   that only fails at peak concurrency passes a smoke test. The mitigation is that
   rollback is fast and cheap; the improvement is per-version error-rate
   monitoring, which is also the prerequisite for canary.
4. **The Jenkins controller is a single point of failure.** No backup of its
   volume yet. Snapshot it, and move builds onto agents.
5. **The scan will occasionally fail a build nobody touched.** Vulnerability
   databases update daily, so a green build can go red on the same code. That is
   the gate working; the team needs to recognise it. Every build archives its scan
   report so the diagnosis takes seconds.

## Evidence

Everything above is verifiable by running something, not by looking at a
screenshot:

| Claim | How to check it |
|---|---|
| Bad commits are blocked | Build the `broken/order-id-collision` branch — fails at Test |
| Vulnerabilities block a release | Build `broken/vulnerable-dependency` — fails at Security Scan on Log4j |
| No hardcoded credentials | `./scripts/check-no-hardcoded-secrets.sh`, which also runs on every build |
| Zero-downtime switch | Poll `/health` in a loop through the load balancer during a release |
| Rollback works | `bluegreen.sh status`, `bluegreen.sh rollback`, `status` again |

Run sheet: `docs/walkthrough.md`. Decisions and their reasoning:
`docs/assumptions-log.md`.
