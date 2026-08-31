# Incident Report

> **Status: template, awaiting the live Day-2 incident.**
>
> Section 6 of the brief says something will be broken without warning during the
> walkthrough, and that the write-up must explain what happened and how a
> recurrence would be prevented. The method below is written in advance
> deliberately — the point of having it ready is that diagnosis under pressure
> follows a process instead of a hunch. Sections 1–7 get filled in from the
> actual failure.
>
> Two real incidents from *building* this pipeline are worked through at the
> bottom, in the same format, as evidence the method is the one actually used.

---

## The method (fixed in advance, on purpose)

1. **Read the actual failure output before forming a theory.** The stage that went
   red, the exact error text, the exit code. Not the stage view's summary — the
   console log. Most wasted debugging time is spent fixing the thing you assumed
   broke.
2. **Establish what is true right now**, before changing anything:
   ```bash
   $SSH ec2-user@$TARGET 'sudo bluegreen.sh status'   # which colour is live, what image, is nginx up
   curl -s -o /dev/null -w '%{http_code}\n' http://$TARGET/health
   ```
3. **Decide whether customers are affected.** If traffic is broken, roll back
   *first* and diagnose afterwards — the rollback needs no diagnosis and costs a
   second:
   ```bash
   $SSH ec2-user@$TARGET 'sudo bluegreen.sh rollback'
   ```
4. **Localise: pipeline, or service?** They fail differently and are fixed
   differently. A red build with `:80` still serving `200` is not an outage.
5. **Find the smallest command that reproduces it.** If it cannot be reproduced
   on demand, it cannot be confirmed fixed.
6. **Fix the cause, not the symptom** — and check whether the same cause has other
   instances. A `chmod` on one host is not a fix if the next `terraform apply`
   recreates the problem.
7. **Make the failure loud next time.** Every one of these should end with
   something that would have caught it: an assertion, a check in the pipeline, or
   a guard in a script.

## 1. Summary

*What broke, in one sentence a non-engineer would understand.*

## 2. Customer impact

*Requests failed / slow / none. For how long. How it was established — the
`/health` poll, the nginx access log, or `bluegreen.sh status`.*

## 3. Timeline

| Time | Event |
|---|---|
| | Symptom first observed |
| | What the console log actually said |
| | First action taken, and why that one |
| | Service confirmed healthy |
| | Cause confirmed (not guessed) |

## 4. Root cause

*The mechanism, not the trigger. "The scan failed" is a symptom; "concurrent
builds share Trivy's cache and it takes an exclusive lock on it" is a cause.*

## 5. What fixed it

*The change, and why that layer. If the fix was on one host rather than in the
repo, say so and say what makes it permanent.*

## 6. What was ruled out, and how

*The theories tested and discarded. Worth recording — it is where most of the time
went, and it is what stops the next person retracing it.*

## 7. Prevention

| Type | Action |
|---|---|
| Make it impossible | |
| Make it loud | |
| Make it documented | |

---

# Worked examples from building this pipeline

Both are real, both were found by running things rather than reading them, and
both are in the git history.

## Incident A — Jenkins came up with zero plugins, and the build was green

**Summary.** The Jenkins controller image built successfully and started, but had
no plugins installed, so JCasC never ran and the controller came up unconfigured.

**Customer impact.** None — pre-production, no traffic. Cost was one full
provision-and-bootstrap cycle.

**Timeline.**

| Time | Event |
|---|---|
| T+0 | `bootstrap-jenkins.sh` reported success and printed a URL |
| T+1m | Jenkins answered on `:8080` and the admin password worked, so it looked fine |
| T+2m | API showed no jobs and no credentials, despite JCasC declaring both |
| T+3m | Re-read the *build* log, not the Jenkins log: `Unable to open /usr/share/jenkins/ref/plugins.txt` — followed by `Done` and a successful layer export |
| T+5m | `docker run --entrypoint sh` into the image: `plugins.txt` was `-rw------- root root` |
| T+6m | Traced to the source: `git clone` in `user_data` had inherited a script-wide `umask 077` |

**Root cause.** `user_data` set `umask 077` before writing a secrets file. That
umask also applied to the `git clone` two lines later, so every file in
`/opt/kente-repo` landed mode 600 root-owned. `docker build` copied those
permissions into the image, and `jenkins-plugin-cli` could not read its own plugin
list — **printing `Unable to open ...` and exiting 0**. So the image built green
with no plugins, and the failure surfaced much later and looked like a JCasC
problem.

**What fixed it.** Three changes at three levels, because the bug had three
enablers:

1. *Root cause* — the umask now applies to a subshell around the one file that
   needs it, so the clone gets normal permissions.
2. *Defence in depth* — `COPY --chown=jenkins:jenkins --chmod=644`, so the image
   no longer inherits whatever mode the file happens to have on the build host.
3. *Make it loud* — the build now asserts at least one plugin `.jpi` exists. A
   pluginless image can never build green again.

**What was ruled out.** JCasC syntax (the file parsed, and the YAML was valid);
the CASC path (the env var and mount were both correct); the secret mount (the key
was present and readable by uid 1000). All three were the obvious suspects because
JCasC was where the symptom appeared.

**Prevention.** The first fix stops it recurring; the third means that if
something similar happens, the *build* fails at the step that caused it rather
than a service failing later for an unrelated-looking reason. Recorded in
`docs/jenkins-setup.md` so the next person does not have to rediscover the umask
interaction.

**The lesson worth keeping.** The proposed quick fix was `chmod -R` on the host.
That would have made the symptom disappear on that one instance and left the next
`terraform apply` broken in exactly the same way.

## Incident B — three builds, three ways for the security scan to die

**Summary.** The first real pipeline run failed on all three branches at the
Security Scan stage, with two different errors, neither of them a vulnerability.

**Customer impact.** None — nothing had been deployed yet. But note the shape: a
scanner that fails for infrastructure reasons is indistinguishable, in the stage
view, from a scanner that found something. That is exactly the ambiguity that
teaches a team to ignore a red build.

**Timeline.**

| Time | Event |
|---|---|
| T+0 | JCasC created the multibranch job, which immediately scanned and started all three branches |
| T+2m | `main`: `Failed to acquire cache or database lock ... cache may be in use by another process: timeout` |
| T+2m | `broken/vulnerable-dependency`: `SIGSEGV` inside `go.etcd.io/bbolt`, mid-scan |
| T+3m | `broken/order-id-collision`: failed at **Test** as designed, never reached the scan |
| T+4m | Cause identified from the two error texts together, not from either alone |

**Root cause.** Trivy stores its vulnerability DB in a bbolt file under a single
cache directory and takes an exclusive lock on it. A multibranch job builds
branches **concurrently**, and `disableConcurrentBuilds()` only serialises runs of
the *same* branch — an assumption I had made and not checked. Three scans started
together: one lost the lock race and timed out, and a second scanned a cache the
first had left corrupt, which segfaulted.

**What fixed it.** `lock(resource: 'trivy-cache')` around the scan steps, plus a
one-off clear of the corrupted cache. A per-build cache directory would also fix
it and needs no plugin, but costs a ~1GB re-download of the vulnerability and Java
DBs on every build. The cache genuinely is an exclusive resource, so a lock models
it honestly: one warm shared cache, one scanner at a time.

**What was ruled out.** A real vulnerability (the finding tables were empty, and
the exit codes were 1 and 2 from fatal errors rather than gate failures); a bad
Trivy pin (the binary ran and downloaded its DB fine); the image (the same image
scanned clean by hand afterwards).

**Prevention.**

| Type | Action |
|---|---|
| Make it impossible | The lock. Two scans cannot run at once. |
| Make it loud | The two Trivy passes are separate steps, so a fatal scanner error is visibly different from a gate failure in the log. |
| Make it documented | Recorded in the Jenkinsfile comment at the lock, in the Assumptions Log, and here — including the wrong assumption about what `disableConcurrentBuilds()` covers, which is the part most likely to be repeated. |
