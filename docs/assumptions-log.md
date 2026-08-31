# Assumptions Log

Kente Retail order-service CI/CD — "No More 2 A.M. Releases"

The brief leaves two things deliberately unspecified and grades whether they get
decided and justified rather than guessed. Those are first. Everything after is a
call I made that a reviewer could reasonably have made differently, recorded so
the reasoning is inspectable rather than implied.

---

## 1. Where Jenkins runs

**Decision.** Jenkins runs as a container on its own EC2 host, built from
`infra/jenkins/Dockerfile`, configured entirely by JCasC
(`infra/jenkins/jenkins.yaml`), started by `infra/jenkins/bootstrap.sh`.

**Why a container rather than a package install.** The pipeline needs the Docker
CLI, Maven and Trivy. The stock Jenkins image has none of them. The two ways to
get there are installing them on every build, or having a controller image that
already contains them. The second is faster and, more importantly, reproducible:
the Dockerfile plus `plugins.txt` plus `jenkins.yaml` *is* the install, and
`docker build` is the whole recovery procedure. Nothing about this controller
exists only as a memory of what someone clicked.

**Why its own host, not the deploy target.** If Jenkins lives on the box it
deploys to, a bad deploy can take out the pipeline you would use to fix it. The
cost of separating them is one t3.small.

**Why not a managed service (CodeBuild, GitHub Actions).** The module objective is
explicitly to install and configure Jenkins and own that setup. A managed runner
would satisfy the *pipeline* objective while skipping the one being assessed.

**What I would change in production.** The controller is a single point of failure
with no backup of `jenkins_home`. In production I would run builds on agents
rather than the built-in node, snapshot the EBS volume, and put the controller
behind an ALB with TLS instead of exposing `:8080` to a single IP.

## 2. How much manual approval a production deploy needs

**Decision.** Exactly one approval gate, on `main` only, immediately before
traffic moves. Build, test, containerize, security scan and the deploy to the idle
colour all run unattended. A 30-minute timeout on the gate.

**Why there and not earlier.** Everything before the switch is reversible and
reaches no customer. The new version is already running and already smoke-tested
on the idle colour when the gate is reached, so a human is being asked a genuinely
useful question — "shall this become live?" — with evidence already in hand,
rather than "shall we start?" with nothing to look at. Gating earlier only costs
feedback speed, and slow feedback is what makes people batch changes into a
Saturday-night release in the first place.

**Why a gate at all, given the rollback is automatic.** The CTO's actual complaint
is not that deploys fail; it is that they happen at times and in ways nobody
chose. One click is a cheap way to keep the *timing* of a release a human
decision. The blue-green rollback covers the "it broke anyway" case, and the two
controls do different jobs.

**What I would change in production.** The gate should be automatic outside a
change-freeze window and manual inside it, and it needs an on-call rota so
"waiting for approval" cannot itself become the 2 a.m. problem. That needs answers
from the client (see §9).

---

## 3. The "deliberately broken commit" was not in the starter zip

**Finding.** The brief says the starter repo ships "one deliberately broken commit
from the pool above." `07-cicd.zip` does not contain one. Its history is three
clean commits and the working tree matches `HEAD` exactly:

```
20d8450  Initial scaffold: Maven project for order-service
a622365  Add order-service REST API with /health and /api/orders, plus unit tests
00a5ff4  Add Dockerfile and a partially-working Jenkinsfile   <- HEAD
```

I verified this by decompressing every object in `.git/objects` — there is no
fourth commit, no stash, no second branch, and no uncommitted modification.

**What it does ship is the defect's fingerprint.** Two things in the seeded code
only make sense together:

- `OrderController.java` starts its ID sequence at 2000, with a comment explaining
  that starting at 1000 would make the first generated ID `ORD-1001` and collide
  with the `listOrders()` fixtures.
- `OrderControllerTest.placeholderRegressionCheck()` is `assertTrue(true)`, with a
  TODO saying it was left as a placeholder "before the checkout-fix work landed."

Read together: the starter contains the *fix* for a collision defect, and nothing
defending it. That is a regression waiting to happen, and the placeholder is where
the test belongs.

**Decision.** I wrote the missing assertion
(`generatedIdsNeverCollideWithSeedFixtures`, plus a uniqueness check), then
reintroduced the defect on `broken/order-id-collision` as the change a
well-meaning developer would actually make — with a tidy-up commit message that
sounds entirely reasonable:

> "Tidy up order ID sequence to start at ORD-1001. The 2000 offset looked
> arbitrary and generated IDs should read consecutively from the fixtures."

The pipeline fails it at the Test stage with
`generated order ID collided with a seed fixture: ORD-1001`.

**Why this is a reconstruction and not an invention.** The defect, its trigger
value, and the exact test that catches it are all specified by the seeded code. I
did not choose the bug; I restored the one the starter was written around. If the
assessor has the intended broken commit, pointing the same test at it should
require no changes.

## 4. Images ship over SSH, not through a registry

**Decision.** `docker save | gzip | ssh 'docker load'` instead of pushing to ECR
and pulling on the target.

**Why.** It removes a paid service and a second credential from a pipeline whose
job is partly to prove that credentials are handled properly. Fewer secrets is a
smaller attack surface, and there is exactly one deploy target.

**Where this stops being right.** Two targets, or an image much larger than this
one, and the transfer cost stops being free — every host pays for the whole image
over SSH instead of pulling shared layers. At that point this becomes ECR plus an
instance profile on the targets. It is a deliberate trade for a single-target
environment, not a claim that registries are unnecessary.

## 5. The Trivy gate uses `--ignore-unfixed`

**Decision.** The gate fails on `CRITICAL` findings that have a fix available.
Unfixed criticals are reported and archived but do not block.

**Why.** A gate that fires on findings nobody can act on is a gate people learn to
bypass, and a bypassed gate is worse than no gate because it also lies to you in
the stage view. The informational pass still surfaces everything, so unfixed
criticals are visible and can be tracked; they just cannot hold a release hostage
to an upstream maintainer.

**Evidence this is not a loophole.** On its first real run, the gate failed `main`
on four fixed CRITICAL CVEs in Tomcat 10.1.20, which arrived with Spring Boot
3.2.5 and had been in the image since the module started. See commit `e33baf0`.
The gate found a real vulnerability in real code on day one.

**Related decision.** I fixed those by overriding `tomcat.version` to 10.1.59
rather than bumping Spring Boot. Overriding a managed dependency version is Spring
Boot's own documented mechanism, and a Tomcat patch release has a much smaller
blast radius than a framework upgrade the week before Kente Fest. The override
should be removed at the next Spring Boot upgrade, not carried forward — noted in
`pom.xml` so it does not become permanent by accident.

**A known property of this gate.** It depends on a vulnerability database that
changes daily, so a build that passed yesterday can fail today with no code
change. That is correct behaviour, not a bug, but it means "the pipeline went red
and nobody touched anything" has a legitimate explanation the team needs to
recognise. The archived Trivy report on every build exists so that diagnosis takes
seconds.

## 6. One keypair for the whole lab

**Decision.** Terraform generates a single RSA keypair. It is the EC2 key pair for
`ec2-user` on both hosts, and the same public half authorises the `deploy` user on
the target. The private half becomes the `kente-deploy-ssh` Jenkins credential.

**Why.** Key *generation* is the part that matters here — the credential is created
by Terraform, exists for the life of the lab, and dies with
`scripts/teardown.sh`. Nothing is reused from another module and nothing is typed
by hand.

**Why the key is not in `user_data`.** Anything that can reach the instance
metadata service can read `user_data`, so a private key placed there is
effectively world-readable from inside the box. `scripts/bootstrap-jenkins.sh`
hands it over on stdin into `sudo tee` instead, so it never lands in `/tmp`, in
shell history, or in metadata.

**What I would change in production.** Separate keys per role, and the deploy key
in SSM Parameter Store or Secrets Manager with an instance profile, so rotation
does not mean re-running a script on a laptop. I did not do that here because it
adds an IAM role, a policy and a KMS grant to a two-host sandbox — more moving
parts to fail live, for a key whose whole lifetime is one lab session.

## 7. The deploy user's privileges

**Decision.** `deploy` is in the `docker` group and has exactly one `sudo`
entitlement: `/usr/local/bin/bluegreen.sh`.

**Why the script is installed by the host bootstrap, not shipped by the pipeline.**
If the pipeline could overwrite the one script `deploy` may run as root, then
`deploy` would effectively have a root shell. The script is root-owned, mode 755,
and installed from the repo by `infra/target-host/bootstrap.sh`. The trade is that
changing it means re-running that bootstrap (`git pull` then one command) rather
than just pushing — the right way round for a sudo-able file.

**Honest limitation.** Membership in the `docker` group is root-equivalent on any
host, so this is defence-in-depth and tidiness, not a security boundary. Removing
it would mean the deploy user cannot run containers at all, which is the job.
Recorded here rather than left to be discovered.

## 8. Smaller calls, briefly

| Call | Reasoning |
|---|---|
| nginx on the target rather than an ALB | The switch has to be demonstrable in seconds and the brief rules out significant new spend. An ALB adds ~$16/month and a slower switch, for realism this environment does not need. |
| Colour ports bound to `127.0.0.1` | The only route to the service from outside is nginx, so "which colour is live" cannot be bypassed by hitting a port directly. |
| `nginx -t` before every reload, with revert | A malformed upstream file would otherwise take down `:80` during a switch — the one moment you cannot afford it. |
| Both hosts clone the repo and run bootstrap scripts from it | One source of truth for `nginx.conf`, `bluegreen.sh`, `plugins.txt` and `jenkins.yaml`. A config change is a `git pull`, not an instance rebuild. |
| `disableConcurrentBuilds()` | Two runs would read the same live colour and both switch. It is the one race this design cannot survive. |
| Image tags carry the short commit SHA | "Which commit is live right now" is the first question in an incident, and a build number alone cannot answer it. |
| Slack notification cannot fail a build | A broken webhook must not look like broken code. A missing credential skips, a failed post is caught. |
| `admin_cidr` has no default | The only convenient default is `0.0.0.0/0`, and an internet-exposed Jenkins is a finding. A validation rule rejects it explicitly. |

## 9. What I would ask the CTO in a real engagement

Unanswerable from the brief, and each one would change the build:

1. **Who clicks the approval gate, and when are they not available?** A gate with
   no owner out-of-hours is a new way to be paged at 2 a.m. — the opposite of the
   goal.
2. **What is the acceptable rollback window?** "Zero downtime" is a shape, not a
   number. This design switches in well under a second and rolls back in about the
   same; if the real requirement is expressed in dropped requests rather than
   seconds, the verification needs to change.
3. **Is there a change freeze around Kente Fest, and does it apply to rollbacks?**
   A freeze that blocks rollbacks is worse than no freeze.
4. **Does the order data survive a deploy?** This service is stateless, so
   blue-green is nearly free. The moment a schema is involved, both colours share
   one database and every release needs backward-compatible migrations. That is the
   next conversation, and a much bigger one than this pipeline.
5. **What is the client's actual risk threshold for shipping a known
   vulnerability?** Blocking on CRITICAL-with-fix is my interpretation. If their
   appetite differs, that threshold is one flag — and it should be their call, not
   mine.
