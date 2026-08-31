# Jenkins, owned rather than assumed.
#
# The stock image has no docker CLI, no Maven and no Trivy, so a pipeline that
# needs all three would either install them on every build or quietly depend on
# a hand-configured controller. Baking them in makes the controller
# reproducible: this file plus plugins.txt plus jenkins.yaml is the whole
# install, and `docker build` is the whole recovery procedure.

FROM jenkins/jenkins:lts-jdk17

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg openssh-client maven jq gzip \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI only -- the daemon is the host's, reached through the mounted
# socket. No docker-in-docker.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Trivy, pinned to a version whose release asset actually resolves (0.63.0 was
# not a published GitHub release, which is how this pin was caught).
# An unpinned scanner is a pipeline that can start failing for
# reasons unrelated to the code.
ARG TRIVY_VERSION=0.74.0
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        | tar -xz -C /usr/local/bin trivy \
    && trivy --version

USER jenkins

# --chmod so the build does not inherit whatever mode the file happens to have
# on the build host. Without it, a restrictive umask on the host produces an
# image whose plugin list the jenkins user cannot read.
COPY --chown=jenkins:jenkins --chmod=644 plugins.txt /usr/share/jenkins/ref/plugins.txt

# The `ls` is the point: jenkins-plugin-cli prints "Unable to open <file>" and
# then exits 0, so without an explicit check a completely pluginless Jenkins
# builds successfully and only fails later, in JCasC, for a reason that looks
# unrelated.
RUN jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt \
    && ls /usr/share/jenkins/ref/plugins/*.jpi >/dev/null 2>&1
