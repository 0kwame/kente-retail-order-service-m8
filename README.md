# order-service (Kente Retail)

A small Spring Boot REST service for Kente Retail's order pipeline. This is the
**Phase-1 fallback starter** for the CI/CD module ("No More 2 A.M. Releases") --
use your own containerized Phase-1 service instead if it's further along; use
this if it isn't.

## What's here

- `pom.xml` -- Maven build, Java 17, Spring Boot 3.2.
- `src/main/java/...` -- the service itself: `GET /health`, `GET /api/orders`,
  `POST /api/orders`.
- `src/test/java/...` -- a starting unit test suite. Not exhaustive -- one test
  is a placeholder (see the `TODO` in `OrderControllerTest`).
- `Dockerfile` -- multi-stage build (Maven build stage, slim JRE runtime stage).
- `Jenkinsfile` -- a **partially-working** pipeline. It builds, tests, and
  containerizes the service. It does **not** yet meet the brief. Look for the
  `TODO(learner)` comments -- there are three gaps left on purpose:
  1. The security-scan stage runs Trivy but never fails the build on what it
     finds.
  2. The deploy stage authenticates with a password typed directly into the
     Jenkinsfile instead of a Jenkins credential.
  3. There is no blue-green environment, traffic switch, or rollback path --
     it deploys straight over the single running container.

## Running it locally

```bash
mvn spring-boot:run
# or, containerized:
docker build -t order-service:local .
docker run --rm -p 8080:8080 order-service:local
```

Then:

```bash
curl localhost:8080/health
curl localhost:8080/api/orders
```

## Building the CI/CD pipeline

Your job is to take the `Jenkinsfile` in this repo from "partially working" to
meeting every Acceptance Criterion in the Learner Brief: Jenkins credentials
for every secret, a security-scan stage that actually gates the build, and a
blue-green deployment with a demonstrated rollback. Everything else about how
you get there -- where Jenkins runs, how much manual approval a deploy needs --
is yours to decide and justify in the Assumptions Log.
