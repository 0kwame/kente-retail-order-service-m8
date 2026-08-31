# Jenkins Setup

How this controller was installed, why it is shaped this way, and how to rebuild
it. The short version: **nothing about this Jenkins was configured by hand.** The
install is three files in `infra/jenkins/`, and `scripts/bootstrap-jenkins.sh` is
the whole procedure.

---

## Topology

```
   your machine                    jenkins-host (EC2)               deploy-target (EC2)
  ┌──────────────┐               ┌─────────────────────┐          ┌──────────────────────┐
  │ terraform    │──provisions──▶│ docker              │          │ nginx :80            │
  │ bootstrap.sh │──deploy key──▶│  └─ jenkins :8080   │──SSH────▶│  └─ upstream ──┐     │
  └──────────────┘               │     (built here)    │  as      │                ▼     │
        │                        │                     │  deploy  │  blue  127.0.0.1:8081│
        └── :8080 (your IP only) └─────────────────────┘          │  green 127.0.0.1:8082│
                                                                   └──────────────────────┘
```

Two hosts, not one, so a bad deploy cannot take out the pipeline you would use to
fix it. The colour ports bind to loopback, so nginx is the only route in.

## The install is three files

| File | Role |
|---|---|
| `infra/jenkins/Dockerfile` | The controller image: Jenkins LTS + Docker CLI + Maven + Trivy (pinned) |
| `infra/jenkins/plugins.txt` | Every plugin, and nothing else |
| `infra/jenkins/jenkins.yaml` | JCasC: security realm, credentials, global env, and the job itself |

`infra/jenkins/bootstrap.sh` builds and runs it. That is the entire install. To
rebuild the controller from nothing: `terraform apply`, then
`scripts/bootstrap-jenkins.sh`.

### Why a custom image

The stock `jenkins/jenkins` image has no Docker CLI, no Maven and no Trivy, and
this pipeline needs all three. The alternatives are installing them on every
build (slow, and a build that can fail for reasons unrelated to the code) or
baking them in. Baked in also means the image *is* the documentation: there is no
gap between what the controller has and what the repo says it has.

The Docker CLI only — no Docker-in-Docker. The container uses the host's daemon
through a mounted socket, and is given the host's `docker` group id at run time
(`--group-add`) so Jenkins does not run as root.

### Why JCasC rather than the setup wizard

A hand-configured controller is state that exists in exactly one place and can
only be recovered by someone remembering what they clicked. With JCasC:

- the two credentials the pipeline needs are declared in a file under review;
- the multibranch job is declared in the same file, so "which branches get built"
  is answerable from the repo;
- rebuilding after a total loss is `terraform apply` plus one script.

`-Djenkins.install.runSetupWizard=false` is set because the wizard's job — create
an admin user, pick plugins — is done by `jenkins.yaml` and `plugins.txt`.

## Credentials

Two, both declared in `jenkins.yaml`, both referenced from the `Jenkinsfile` by id
only.

| Id | Kind | Used for | Where the value comes from |
|---|---|---|---|
| `kente-deploy-ssh` | SSH private key | Every SSH and `docker save` pipe to the deploy target | `/run/secrets/kente_deploy_key`, mounted read-only from `/etc/kente-secrets` on the host |
| `kente-slack-webhook` | Secret text | The failure notification | `SLACK_WEBHOOK_URL` in the container env, from `/etc/kente-jenkins.env` |

JCasC resolves `${kente_deploy_key}` through its Docker-secret source, which reads
files from `/run/secrets/`. So the key exists as a file on the host and as a
credential in Jenkins, and in neither case as a literal in any tracked file.

### Why the key is handed over by a script rather than by Terraform

`user_data` is readable by anything that can reach the instance metadata service,
so a private key placed there is effectively world-readable from inside the box.
`scripts/bootstrap-jenkins.sh` pipes it over SSH straight into `sudo tee`, so it
never lands in `/tmp`, in shell history, or in metadata. The cost is that starting
Jenkins is a deliberate second step instead of happening at boot — which is also
why JCasC never starts before the credential it needs exists.

## Standing it up

```bash
cd infra
terraform init
terraform apply \
  -var "admin_cidr=$(curl -s https://checkip.amazonaws.com)/32" \
  -var "jenkins_admin_password=<choose one>" \
  -var "slack_webhook_url=<optional, empty is fine>"

cd .. && ./scripts/bootstrap-jenkins.sh
```

`bootstrap-jenkins.sh` waits for SSH and cloud-init on both hosts, installs the
deploy key, pulls the repo on the Jenkins host, builds the image and starts the
container, then prints the URL. It is idempotent — re-run it after changing
`jenkins.yaml`, `plugins.txt` or the `Dockerfile`.

## Changing the configuration afterwards

There is no "log in and click" path. Change the repo, then:

```bash
git push
./scripts/bootstrap-jenkins.sh     # rebuilds and restarts the controller
```

`jenkins_home` is a named Docker volume, so job history and build logs survive
the rebuild. That matters here: the failed builds on the `broken/*` branches are
deliverable evidence.

For the deploy target, the equivalent is:

```bash
ssh ec2-user@<target> 'sudo git -C /opt/kente-repo pull && sudo bash /opt/kente-repo/infra/target-host/bootstrap.sh'
```

That bootstrap is idempotent too, and deliberately will **not** move traffic: it
only seeds the nginx upstream file if it does not already exist, so re-running it
during an incident cannot silently switch colours.

## Two failures worth recording

Both were found by standing this up for real rather than by reading it.

**1. A pluginless Jenkins built green.** `user_data` set `umask 077` before
writing the env file, and that umask also applied to the `git clone` two lines
later. Every file in `/opt/kente-repo` landed mode 600 root-owned, `docker build`
copied those permissions into the image, and `jenkins-plugin-cli` could not read
its own plugin list. It printed `Unable to open ...` **and exited 0**, so the
image built successfully with zero plugins and the failure only surfaced later, in
JCasC, looking like something else entirely.

Fixed at three levels: the umask now applies to a subshell around the one file
that needs it; `COPY --chown --chmod` makes the image independent of host file
modes; and the build now asserts that at least one `.jpi` exists, so a pluginless
image cannot build green again.

**2. A pinned version that did not exist.** The Trivy pin was `0.63.0`, a version
string that exists in the wild but has no published GitHub release asset. The
image build failed with a 404. Now pinned to `0.74.0`, whose asset URL was checked
before committing. Pinning is still right — an unpinned scanner is a pipeline that
can go red for reasons unrelated to the code — but a pin is a claim that needs
verifying.

## Known limitations

- **The controller is a single point of failure.** No backup of `jenkins_home`. In
  production: snapshot the volume, and run builds on agents rather than the
  built-in node.
- **`:8080` is plain HTTP**, reachable only from `admin_cidr`. Acceptable for a
  sandbox behind a single-IP allowlist; in production it belongs behind an ALB
  with TLS.
- **The approval gate holds an executor while it waits.** Fine at two executors;
  move that stage to `agent none` if the controller ever gets busy enough for that
  to queue real work.
