# Defence Walkthrough — Run Sheet

15–20 minutes, live. Every claim in the submission is proven by running something
here. Nothing depends on a screenshot.

Set these once, at the start of the session:

```bash
cd order-service/infra
export PEM=$(terraform output -raw private_key_path)
export JENKINS=$(terraform output -raw jenkins_url)
export TARGET=$(terraform output -raw target_public_ip)
export SSH="ssh -i $PEM -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
cd ..
```

Using `terraform output` rather than pasted IPs means this sheet stays correct
after a re-provision.

---

## Pre-flight (do this 20 minutes before, not during)

**Check your IP first.** The security groups allow exactly one address, and a
home or ISP address changes without warning — ours changed overnight mid-lab and
locked us out of both hosts. The symptom is not an error, it is *everything
timing out*, which is a terrible thing to start diagnosing in front of an
assessor.

```bash
# does the SG still allow you?
curl -s https://checkip.amazonaws.com
# if it has changed, re-apply -- this is safe and takes ~15s, nothing is replaced
cd infra && terraform apply -auto-approve \
  -var "admin_cidr=$(curl -s https://checkip.amazonaws.com)/32"
```

`admin_cidr` is deliberately not stored in `terraform.tfvars`, so every apply
looks it up fresh rather than reusing a stale value.

| Check | Command | Want |
|---|---|---|
| Jenkins answers | `curl -sI $JENKINS/login \| head -1` | `200` |
| Plugins actually installed | `$SSH ec2-user@${JENKINS#http://} 'sudo docker exec jenkins ls /var/jenkins_home/plugins \| wc -l'` | well above 12 |
| Target healthy | `$SSH ec2-user@$TARGET 'sudo bluegreen.sh status'` | a live colour, nginx reachable |
| Trivy DB is warm | Run a build on `main` once | green |
| **Both colours running** | `$SSH ec2-user@$TARGET 'sudo bluegreen.sh status'` | blue *and* green present |

**The last one matters.** On a fresh target only one colour has ever been
deployed, so `rollback` correctly refuses — there is nothing to go back to. **Run
the `main` pipeline twice before the walkthrough** so both colours hold an image.
Build #1 makes green live; build #2 makes blue live; then the rollback demo has
somewhere to go.

Also worth knowing before you are asked: the scan gate depends on a vulnerability
database that updates daily, so `main` can go red with no code change. That is the
gate working, and the archived `trivy-report.txt` on the build names the finding.
If it happens live, say so and read the report — it is a better answer than a
green build.

---

## 1 · The problem, in the code (2 min)

Open the seeded `Jenkinsfile` at commit `00a5ff4` — the state it was handed over
in — and show the three lines that matter:

```bash
git show 00a5ff4:Jenkinsfile | grep -n "exit-code 0\|sshpass\|docker rm -f"
```

Say: *three separate ways to have a bad night. A scan that reports and blocks
nothing, a password in the file, and a deploy that stops the running container
before starting the new one.*

Then prove the last one is not rhetorical:

```bash
git show 00a5ff4:Jenkinsfile | sed -n '/stage(.Deploy.)/,/^        }/p'
```

## 2 · Credentials (2 min)

```bash
./scripts/check-no-hardcoded-secrets.sh
git stash list >/dev/null; git show 00a5ff4:Jenkinsfile > /tmp/seeded-Jenkinsfile
./scripts/check-no-hardcoded-secrets.sh /tmp/seeded-Jenkinsfile   # fails, as it must
```

Say: *the check passes on today's tree and fails on the version we were handed. A
check that has never been run against a failing input is not a check.*

Then, in Jenkins: **Manage Jenkins → Credentials** — two credentials, both declared
in `infra/jenkins/jenkins.yaml`, neither typed into a UI.

## 3 · A green release, live (5 min)

Start the `main` build in Jenkins. While it runs, open a second terminal:

```bash
while true; do
  printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://$TARGET/health)"
  sleep 0.3
done
```

**This loop is the zero-downtime evidence.** It must show an unbroken run of `200`
straight through the traffic switch.

Talk through the stages as they go:

- **Test** — five real assertions, including the one the starter left as
  `assertTrue(true)`.
- **Security Scan** — two passes. Point out the archived `trivy-report.txt`.
- **Deploy (idle colour)** — note the log line naming which colour is idle, and
  that the smoke test runs here, **before** the gate and before any traffic.
- **Approve Release** — pause here, and use the pause. The prompt names the
  colour and port the new version is already running on, so in another terminal:

  ```bash
  $SSH ec2-user@$TARGET 'curl -s http://127.0.0.1:8082/api/orders'   # the idle colour: new version
  curl -s http://$TARGET/api/orders                                   # customers: still the old one
  ```

  *Two versions of the service, on one host, and customers are on the old one.
  That is why the gate is here and not at the start: the question is "shall this
  become live", with the evidence already in hand.* Then click **Switch traffic**.
- **Switch Traffic** — the `200`s in the other terminal do not break.

## 4 · The broken commit is blocked (3 min)

```bash
git log --oneline -1 broken/order-id-collision
git show broken/order-id-collision --stat
```

Read the commit message out loud — *"Tidy up order ID sequence to start at
ORD-1001"* — and say: *this is what the change actually looks like. Nobody commits
"introduce a bug". It is a tidy-up with a plausible justification, and it silently
makes the first generated order collide with an existing one.*

Build that branch in Jenkins. It goes red at **Test**:

```
generated order ID collided with a seed fixture: ORD-1001
```

Point out that the pipeline never reached the deploy stages — `when { branch
'main' }` — so nothing touched the target.

**If asked where the broken commit came from:** the starter zip did not contain
one. Show it:

```bash
cd .. && git -C order-service log --oneline 00a5ff4   # three commits, that is all
```

Then explain the reconstruction from the seeded fingerprint — the sequence comment
and the placeholder test — and point at `docs/assumptions-log.md §3`. Owning this
is stronger than pretending the commit was supplied.

## 5 · The scan gate is real (2 min)

```bash
git show broken/vulnerable-dependency --stat
```

A plausible commit: *"Add log4j-core for the order-audit log feed."* Build it. Red
at **Security Scan**:

```
org.apache.logging.log4j:log4j-core 2.14.1  CVE-2021-44228  fix 2.15.0
```

Then the better story:

```bash
git show e33baf0 --stat
git log -1 e33baf0 --format=%B
```

Say: *this gate failed on `main` the first time it ran — four CRITICAL CVEs in the
Tomcat that ships with Spring Boot 3.2.5, including an RCE and an auth bypass. Not
our code. It had been in the running image the whole time and nothing was looking.
The pipeline paid for itself before its first deployment.*

## 6 · Rollback, live (3 min)

```bash
$SSH ec2-user@$TARGET 'sudo bluegreen.sh status'
curl -s http://$TARGET/api/orders; echo
```

Restart the `/health` polling loop, then:

```bash
$SSH ec2-user@$TARGET 'sudo bluegreen.sh rollback'
$SSH ec2-user@$TARGET 'sudo bluegreen.sh status'
```

The live colour flips, the loop keeps showing `200`, and the service still serves.

Say: *the previous version never stopped running. That is the whole design — a
rollback is a config reload against a container that is already warm, not a
redeploy. It is about a second, and it does not need a rebuild, a registry, or a
working pipeline.*

Then show that this is also automatic:

```bash
sed -n '/post {/,/^        }/p' Jenkinsfile | head -30
```

*If a build fails after traffic has moved, that runs without anyone asking.
`SWITCH_ATTEMPTED` is set before the switch rather than after, so a half-failed
switch still counts as needing a rollback.*

## 7 · The decisions (2 min)

Have `docs/assumptions-log.md` open. Lead with the two the brief left open:

- **Where Jenkins runs** — its own host, containerised, JCasC. *Separate from the
  deploy target, because if Jenkins lives on the box it deploys to, a bad deploy
  takes out the pipeline you would fix it with.*
- **How much approval** — one gate, immediately before the switch, `main` only.
  *Everything before it is reversible and reaches no customer.*

Then offer the honest limits before being asked — it lands much better volunteered:

- **Database migrations are the real gap.** Blue-green is nearly free here because
  the service is stateless. Add a schema and both colours share one database;
  every release then needs backward-compatible migrations or the rollback is a
  promise that will not hold.
- **`docker` group membership is root-equivalent**, so the narrow `sudo` rule is
  tidiness and defence-in-depth, not a security boundary.
- **A smoke test will not catch a slow leak** — canary would have. The mitigation
  is that rollback is cheap.

---

## Likely questions, and the short answers

| Question | Answer |
|---|---|
| "Why not canary?" | Canary buys earlier detection; blue-green buys instant complete reversal. One stateless service, one host, three weeks before the year's biggest event — reversal is worth more. And canary's advantage needs per-version monitoring that does not exist yet, so it would be a slower blue-green where 5% of customers are the monitoring. Memo has the full comparison. |
| "Why `--ignore-unfixed`?" | A gate that fires on findings nobody can act on is one people learn to bypass, and a bypassed gate also lies in the stage view. Unfixed criticals still appear in the archived report. And it is not a loophole — it caught four real Tomcat CVEs on day one. |
| "Why no registry?" | One target, so `docker save \| ssh docker load` removes a paid service and a second credential. It stops being right at two targets or a much larger image, and then it becomes ECR plus an instance profile. Written down as a trade, not a claim. |
| "What if the switch itself fails?" | `nginx -t` runs before every reload and the previous conf is restored if it fails, so a malformed upstream cannot take down `:80`. And `switch` refuses to move traffic to a colour that is not answering `/health`. |
| "Two builds at once?" | `disableConcurrentBuilds()`. Both would read the same live colour and both switch — the one race this design cannot survive. |
| "How do you know which commit is live?" | Image tags are `<build>-<short sha>`. `bluegreen.sh status` prints the running image. Build number alone cannot answer it, which is why the tag carries both. |
| "What breaks if Jenkins dies?" | Nothing that is serving traffic. Rebuild is `terraform apply` plus `scripts/bootstrap-jenkins.sh`; the install is three files in `infra/jenkins/`. What is lost is build history, since the volume is not backed up yet — that is on the risk list. |

---

## Before teardown: export the evidence

Build history lives on the Jenkins volume and dies with the instance.

```bash
# Console logs for the two branches that must fail, plus the green run
for job in main broken%2Forder-id-collision broken%2Fvulnerable-dependency; do
  out="evidence-$(echo "$job" | tr '/%' '__').txt"
  curl -su "admin:$JENKINS_ADMIN_PASSWORD" \
    "$JENKINS/job/order-service/job/$job/lastBuild/consoleText" -o "$out"
done
ls -la evidence-*.txt
```

Then `./scripts/teardown.sh` to stop the meter.
