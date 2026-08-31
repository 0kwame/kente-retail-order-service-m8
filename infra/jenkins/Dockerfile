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

# Trivy, pinned. An unpinned scanner is a pipeline that can start failing for
# reasons unrelated to the code.
ARG TRIVY_VERSION=0.58.1
RUN curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
        | tar -xz -C /usr/local/bin trivy \
    && trivy --version

USER jenkins

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt
