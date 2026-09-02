# Verified Evidence

Every acceptance criterion, with the run that proves it and the measured result.
All of these are real builds on the provisioned environment — nothing here is a
screenshot or a claim about what the pipeline would do.

Environment: 2 × t3.small, us-east-1. Jenkins `2.541.3`, Trivy `0.74.0`,
Spring Boot `3.2.5` with Tomcat overridden to `10.1.59`.

---

## The six criteria

| # | Criterion | Run | Result |
|---|---|---|---|
| 1 | Jenkins installed and running, learner-owned | `scripts/bootstrap-jenkins.sh` | Controller built from `infra/jenkins/`, 234 plugins, JCasC created the job and both credentials with no UI interaction |
| 2 | Multi-stage pipeline builds, tests, containerizes, deploys via SSH | `main` #5 and #6 | All 10 stages SUCCESS. Image `6-e5089ee` deployed to the target over SSH |
| 3 | Jenkins credentials for every secret, none hardcoded | every build | `check-no-hardcoded-secrets.sh` passes in-pipeline; fails on the seeded `Jenkinsfile` when pointed at it |
| 4 | Security scan fails the build on critical findings | `broken/vulnerable-dependency` #3 | **FAILED at Security Scan.** `CVE-2021-44228` (Log4Shell RCE) CRITICAL in `log4j-core 2.14.1`. Test and Containerize passed first, so the scan is what stopped it |
| 5 | The broken commit is blocked | `broken/order-id-collision` #3 | **FAILED at Test.** `generated order ID collided with a seed fixture: ORD-1001`. Never reached the deploy stages |
| 6 | Blue-green with a demonstrated rollback | `main` #6, then `bluegreen.sh rollback` | Switch blue→green in **969 ms**; rollback green→blue with **0 dropped requests** |

## Zero downtime, as a number

`scripts/availability-probe.sh` polling `/health` through nginx at 200 ms
intervals:

| Event | Probe location | Interval | Samples | Non-200 |
|---|---|---|---|---|
| Rollback, blue → green | **inside AWS** (Jenkins host → target private IP) | 100 ms | 200 | **0** |
| Full release, `main` #6 (969 ms switch) | laptop | 200 ms | 94 | **0** |
| Rollback, blue → green | laptop | 200 ms | 15 | **0** |
| Full release, `main` #2 (989 ms switch) | laptop | 200 ms | 116 | 2 — **not the service**, see below |

"Zero downtime" should be a measurement, not an adjective. Reproduce with:

```bash
./scripts/availability-probe.sh http://<target>   # then release or roll back
```

### Where you measure from changes what you measure

One run showed 2 failures out of 116. They were **not** dropped by the service,
and the reasoning is worth keeping because the same thing will happen in any live
demo run over a home connection:

- The failures were at `10:07:30` and `10:07:32`. The switch ran `10:07:12` to
  `10:07:13` and the build finished at `10:07:14` — so they landed **16 seconds
  after** traffic had already moved.
- The sample gaps were 2.2 s against a normal 0.7 s, meaning curl was hitting its
  2-second timeout rather than receiving an error.
- Decisively, the target's nginx access log shows **every request it received
  answered `200` with `rt=0.003`**, and a gap from `10:07:30` to `10:07:35`. The
  requests never arrived.

So the loss was on the path from a home ISP to AWS. The authoritative number is
the first row of the table: probing from inside AWS, at a tighter interval, across
a rollback — 200 samples, zero failures.

**If you see failures during a live walkthrough, check the access log before
conceding anything.** A request that is not in it never reached the service.

## The vulnerability the gate caught on its first run

Before it had scanned anything written for this lab, the gate failed `main` on
four CRITICAL CVEs in the Tomcat bundled with Spring Boot 3.2.5:

| CVE | Package | Installed | Fixed in |
|---|---|---|---|
| CVE-2025-24813 | `tomcat-embed-core` | 10.1.20 | 10.1.35 |
| CVE-2026-41293 | `tomcat-embed-core` | 10.1.20 | 10.1.55 |
| CVE-2026-43512 | `tomcat-embed-core` | 10.1.20 | 10.1.55 |
| CVE-2026-43515 | `tomcat-embed-core` | 10.1.20 | 10.1.55 |

Fixed in `e33baf0` by overriding `tomcat.version` to 10.1.59. Gate now reports
zero CRITICAL findings on `main`. Reasoning for the override rather than a
framework bump: `docs/assumptions-log.md §5`.

## Blue-green state after the demonstrations

```
live colour   : green  (port 8082)
idle colour   : blue   (port 8081)

order-service-blue    kente-retail/order-service:6-e5089ee   Up   127.0.0.1:8081->8080
order-service-green   kente-retail/order-service:5-db35956   Up   127.0.0.1:8082->8080

  blue  direct  -> 200
  green direct  -> 200
  nginx         -> 200
```

Both colours running is the point: the rollback target is already warm, so
reversing a release costs a config reload rather than a redeploy. Image tags
carry the commit SHA, so "which commit is live" is answerable from
`bluegreen.sh status` alone.

## Live service responses

```
$ curl http://<target>/health
OK

$ curl http://<target>/api/orders
[{"id":"ORD-1001",...},{"id":"ORD-1002",...}]

$ curl -X POST http://<target>/api/orders -d '{"item":"kente-cloth-wrap","quantity":2}'
{"id":"ORD-2003","item":"kente-cloth-wrap","quantity":2}
```

The generated ID is outside the fixture range — the behaviour the regression test
defends and the collision branch breaks.

## Failures found by running this, not reading it

Six defects surfaced only because the environment was built for real. All six are
in the git history with their fixes:

| Defect | How it would have failed | Commit |
|---|---|---|
| `.gitignore` `target/` swallowed `infra/target/bootstrap.sh` | Deploy target boots, cannot find its own bootstrap script | renamed to `infra/target-host/` |
| Trivy pinned to `0.63.0`, not a real release | Jenkins image build 404s | `bff383d` |
| `umask 077` leaked into `git clone` | Jenkins builds green with zero plugins, JCasC silently never runs | `08d25f5` |
| Trivy cache shared across concurrent branch builds | Lock timeout on one branch, SIGSEGV in bbolt on another | `65677fd` |
| `core.fileMode = false` hid every `chmod +x` | `Permission denied` calling pipeline scripts from a fresh checkout | `db35956` |
| `types_hash_max_size 2048` did not silence the nginx warning | A warning on every single traffic switch | corrected after testing on the host |

The last one is worth its own note: the first fix for it was committed with a
message claiming it worked, and it did not. It was caught by reading the reload
output of the next rollback rather than trusting the commit.
