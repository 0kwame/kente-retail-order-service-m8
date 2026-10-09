# Multi-stage build: compile with Maven, ship only the JRE + jar.
#
# Both stages are pinned to a specific release AND its digest. A tag like
# 17-jre moves under you, so two builds of the same commit could differ. The
# digest makes the build reproducible and the tag says what it is.
# "Pinned" is not "safe": the Trivy gate still has to pass on every build, and
# a pin gets old. Both tags were the newest releases on 2026-10-09.
# ponytail: manual bumps; add Renovate/Dependabot for Dockerfile digests when a
# stale pin first fails the Trivy gate.
FROM maven:3.9.16-eclipse-temurin-17@sha256:1a352420f7aba21f5ad08df31bab55f74c013fb491f1ae8ab1dd7ff9ed698584 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -B -q -DskipTests package

FROM eclipse-temurin:17.0.20.1_1-jre-noble@sha256:900322f4cc1b9da9d730ae4bb56d8a1dabbaa9cfa32809fc8b542b600370a045
# Not root: a compromised JVM gets an unprivileged user with no shell and no
# write access to the jar.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /app/target/order-service.jar app.jar
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
