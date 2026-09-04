# Build Evidence

Raw Jenkins console output and archived Trivy reports, exported from the
controller before `scripts/teardown.sh` destroyed it. Build history lives on the
Jenkins volume and dies with the instance, so this is the durable copy.

Every line carries a Jenkins timestamp. Nothing here is a screenshot, and
nothing has been edited — `grep` them.

Environment: 2 × t3.small, us-east-1, 3–4 Sep 2026. Jenkins with 316 plugins
from `infra/jenkins/plugins.txt`, Trivy 0.74.0, Spring Boot 3.2.5 with Tomcat
overridden to 10.1.59.

| File | Build | Proves |
|---|---|---|
| `broken_order-id-collision-build1.log` | `broken/order-id-collision` #1 | **Fails at Test.** A plausible tidy-up commit is blocked before it can be containerized, scanned or deployed |
| `broken_vulnerable-dependency-build1.log` | `broken/vulnerable-dependency` #1 | **Fails at Security Scan.** Test and Containerize pass first, so the scan is demonstrably what stopped it |
| `main-build1.log` | `main` #1 | First green release. Deploys to green on a fresh target |
| `main-build2.log` | `main` #2 | Second green release. Switches green → blue, both colours now warm |
| `main-build3.log` | `main` #3 | Ships a real code change (`currency` field) end to end |
| `trivy-main-build3.txt` | `main` #3 | The informational pass — every CRITICAL/HIGH/MEDIUM finding, archived on every build |
| `trivy-broken_vulnerable-dependency-build1.txt` | `broken/vulnerable-dependency` #1 | The findings that failed the gate |

## The lines worth grepping for

```bash
# acceptance criterion 5 — the broken commit is blocked
grep "collided with a seed fixture" broken_order-id-collision-build1.log
#   org.opentest4j.AssertionFailedError: generated order ID collided with
#   a seed fixture: ORD-1001 ==> expected: <false> but was: <true>

# acceptance criterion 4 — a vulnerability blocks the release
grep -E "CVE-2021-44228.*CRITICAL" broken_vulnerable-dependency-build1.log

# acceptance criterion 6 — the traffic switch, and the rollback still available
grep -E "traffic switched|is live with" main-build3.log
#   bluegreen: traffic switched: blue -> green (previous colour left running
#   for rollback)
#   green is live with kente-retail/order-service:3-d368d7b. blue is still
#   running and one reload away if this goes wrong.

# the smoke test running BEFORE any traffic moves
grep -A4 "smoke: http://127.0.0.1:80" main-build3.log
```

## Stage timings, and why build #1 is slower

| Stage | #1 | #2 | #3 |
|---|---|---|---|
| Build | 33.8s | 7.8s | 8.9s |
| Test | 14.7s | 5.5s | 5.3s |
| Containerize | 49.2s | 27.0s | 22.4s |
| Security Scan | 117.8s | 17.9s | 17.9s |
| Deploy (idle colour) | 23.0s | 21.2s | 20.9s |
| Switch Traffic | 3.5s | 1.0s | 1.1s |
| Verify | 0.7s | 0.7s | 0.7s |

Build #1 pays for a cold Maven repository and a full Trivy vulnerability
database download. Steady-state is what #2 and #3 show. Worth knowing so a cold
first build is not mistaken for a slow pipeline.

`Approve Release` is omitted from the table — its duration is however long a
human took to click, which on #1 was 1064s because nobody was watching.

## What is not here

**The rollback demonstration.** It needs a live target and both colours warm;
the environment was torn down before it was run on AWS. It *was* verified
locally against the same `bluegreen.sh` — see the walkthrough — and that run
also surfaced a defect: `rollback` means "switch to the other colour", not "go
back to the previous version", so calling it twice returns you to the version
you were escaping. Recorded rather than quietly fixed.

**A zero-downtime probe log for these builds.** The measurement was taken
separately with `scripts/availability-probe.sh`: 230 samples at 300 ms across a
full release, 0 non-200, measured from a laptop over the public internet to
`us-east-1`. Figures in `docs/verified-evidence.md`.
