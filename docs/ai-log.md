# AI Log

AI (Claude, via Claude Code) was used throughout this lab. This log records what
it was asked for, what was taken as-is, what was rejected or corrected, and why.
Every claim in the "verified" column was checked by running something, not by
reading the output and finding it plausible.

The pattern that mattered most: **AI output that asserted a fact about the
environment was wrong more often than AI output that wrote code.** Three of the
five defects below were confident, well-reasoned statements about things that were
not true. Code that does not compile announces itself; a wrong premise does not.

---

## Rejected, and why

### 1. "The starter zip contains a deliberately broken commit"

**Asserted because the brief says so.** The brief states the starter repo ships
"one deliberately broken commit from the pool above," and the natural move is to
go looking for it and, failing that, invent one.

**Rejected.** I decompressed every object in `07-cicd.zip`'s `.git/objects`
directly rather than trusting either the brief or a summary of the repo. There are
exactly three commits, one branch, no stash, and the working tree is byte-identical
to `HEAD`. The commit does not exist.

**What replaced it.** Instead of inventing a bug, I read what the starter *did*
ship: a sequence offset with a comment explaining the collision it avoids, sitting
next to a placeholder test asserting `true` in exactly the position where the test
for that collision belongs. The defect is fully specified by the starter even
though the commit is missing. `broken/order-id-collision` restores it, and the
Assumptions Log states plainly that it is a reconstruction and shows the reasoning.

**Why this matters more than the code.** Accepting the premise would have produced
a bug I chose, defended as a bug the lab chose. The finding — and the ability to
show the object dump — is worth more than the branch.

### 2. Two Trivy version pins that did not exist

**Suggested:** `TRIVY_VERSION=0.58.1`, chosen for no reason beyond looking recent.
Then, after local verification, `0.63.0` — the version I had actually tested with.

**Rejected both.** The image build failed with a 404 on `0.63.0`. Checking the
GitHub releases API showed that `v0.63.0` has no published release at all, despite
being a version string that exists in the wild. `0.74.0` was verified to resolve
with an actual HTTP request *before* being committed.

**Kept the principle, fixed the practice.** Pinning is still right — an unpinned
scanner is a pipeline that goes red for reasons unrelated to the code. But a pin
is a claim, and claims get checked.

### 3. Gating the build on HIGH as well as CRITICAL

**Suggested** as the stricter, more responsible-looking option.

**Rejected.** A gate that fires constantly is a gate the team learns to bypass,
and a bypassed gate is worse than no gate because it also lies in the stage view.
The build gates on CRITICAL-with-an-available-fix and reports everything else. The
threshold is argued in the Assumptions Log rather than just chosen, and it is
flagged as the client's call to make, not mine.

### 4. Putting the deploy private key in Terraform's `user_data`

**Suggested** because it makes the whole environment come up in one
`terraform apply` with no manual step.

**Rejected.** `user_data` is readable by anything that can reach the instance
metadata service, so a private key there is effectively world-readable from inside
the box — a poor look in a lab partly about credential handling.
`scripts/bootstrap-jenkins.sh` pipes the key over SSH into `sudo tee` instead, so
it never touches `/tmp`, shell history, or metadata. The cost is one deliberate
extra step, which is also documented as the Jenkins install procedure.

### 5. Having the pipeline copy `bluegreen.sh` to the deploy target on every run

**Suggested** so the script on the target always matches the pipeline version.

**Rejected.** The `deploy` user has one `sudo` entitlement, and it is that script.
If the pipeline could overwrite it, `deploy` would effectively have a root shell —
the pipeline's own credential would become a privilege-escalation path. The script
is installed root-owned by the host bootstrap instead. Changing it costs a `git
pull` and one command, which is the right friction for a file that runs as root.

### 6. An XML comment containing `--`

**Written** into `pom.xml` as ordinary prose punctuation.

**Rejected by Maven**, which is the correct reviewer: `--` is illegal inside an XML
comment. Caught by running `mvn test` rather than by reading the diff.

---

## Accepted, but only after changing it

### The Tomcat fix

AI's first instinct on four CRITICAL Tomcat CVEs was to bump Spring Boot. I chose
to override `tomcat.version` instead. Both fix the CVEs; the override's blast
radius is a Tomcat patch release rather than a whole framework upgrade, which is
the right trade three weeks before Kente Fest. The reasoning, and the instruction
to remove the override at the next Spring Boot upgrade rather than carry it
forward, are both recorded in `pom.xml` where whoever does that upgrade will see
them.

### `docker save | ssh docker load` instead of a registry

Accepted, because it removes a paid service and a second credential. But accepted
*with its ceiling written down*: with more than one target, or a larger image,
every host pays for the whole image over SSH instead of pulling shared layers, and
this should become ECR plus an instance profile. Recorded in the Assumptions Log so
it reads as a trade rather than a claim that registries are unnecessary.

---

## Accepted as-is, and verified

| Output | How it was verified |
|---|---|
| The regression test for the ID collision | Reintroduced `AtomicInteger(1000)` locally and confirmed the test fails with `generated order ID collided with a seed fixture: ORD-1001`, then reverted |
| The Trivy gate blocks a vulnerable dependency | Built the image with Log4j 2.14.1 and ran the exact gate command: exit 1 on CVE-2021-44228 and CVE-2021-45046 |
| The gate does *not* block a clean build | Ran the same command against `main` after the Tomcat fix: zero CRITICAL findings, exit 0 |
| `smoke.sh` | Ran against the real service on `localhost:8080`: all three checks pass; verified it fails when nothing is listening |
| Terraform | `terraform validate`, `terraform fmt`, and both `user_data` templates rendered through `terraform console` to check escaping before any apply |
| `jenkins.yaml` | Parsed as YAML before shipping |
| Every shell script | `bash -n`, then run for real on the provisioned hosts |
| The hardcoded-secret check | Ran against the *unfixed* Jenkinsfile first and confirmed it fails on the seeded password — a check never run against a failing input is not a check |

---

## Two defects AI introduced that only running things caught

Both are the same shape: code that was locally correct and globally wrong.

**`.gitignore` swallowed a file the deploy target needed to boot.** The seeded
`.gitignore` contains `target/` for Maven. A new directory at
`infra/target/bootstrap.sh` matched it and was silently never committed. Nothing
errored — `git add -A` simply did not add it, and the deploy target would have
booted and failed to find its own bootstrap script. Caught by reading `git status`
output carefully rather than assuming the add worked, then confirmed with
`git check-ignore -v`. Fixed by renaming to `infra/target-host/`.

**A `umask` leaked out of the one line it was for, and produced a Jenkins with no
plugins.** `user_data` set `umask 077` before writing a secrets file, and that
umask also applied to the `git clone` two lines later. Every repo file on the host
landed mode 600 root-owned, `docker build` copied those permissions into the image,
and `jenkins-plugin-cli` could not read its own plugin list — printing
`Unable to open ...` **and exiting 0**. The image built green with zero plugins,
and the failure surfaced much later in JCasC looking like an unrelated problem.

That second one is the most instructive thing in this log. The fix went in at three
levels rather than one: the umask now scopes to a subshell (root cause);
`COPY --chown --chmod` makes the image independent of host file modes (defence in
depth); and the build now asserts at least one plugin `.jpi` exists, so a
pluginless image cannot ever build green again (make the failure loud). AI's first
proposed fix was `chmod -R` on the host — which would have made the symptom go
away on that one instance and left the next `terraform apply` broken in exactly the
same way.

---

## How AI was used, honestly

- **Useful for:** first drafts of long mechanical files (Terraform, JCasC, the
  Jenkinsfile scaffolding), remembering exact flag syntax, and writing the
  scaffolding of these documents.
- **Not trusted for:** any statement about what a file contains, what a version
  number is, or whether something works. Those were checked by running them.
- **The recurring failure mode:** confident, well-argued, wrong assertions about
  the environment. A wrong version pin and a nonexistent commit both arrived with
  entirely reasonable justifications attached. Fluent reasoning is not evidence.
- **What I would tell someone else using AI on this lab:** the code it writes is
  mostly fine. The facts it states about your repo, your zip file and your
  dependency versions are the part that will cost you the defence.
