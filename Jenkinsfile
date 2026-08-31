// Kente Retail -- order-service pipeline.
//
// STATUS: partially working. It builds, tests, and containerizes the
// service, but it does not meet the brief yet -- see the TODO(learner)
// comments below for the three gaps you need to close:
//   1. CLOSED -- Security Scan now gates on CRITICAL findings.
//   2. CLOSED -- Deploy authenticates with a Jenkins SSH credential.
//   3. There is no blue-green environment, traffic switch, or rollback --
//      it just overwrites the one container that's already running.
//
// Where Jenkins itself runs and how much manual approval "Deploy" needs are
// yours to decide -- this file doesn't assume either for you.

pipeline {
    agent any

    environment {
        IMAGE_NAME  = "kente-retail/order-service"
        IMAGE_TAG   = "${env.BUILD_NUMBER}"
        // DEPLOY_HOST is NOT set here. It is a controller-wide env var set by
        // JCasC from the Terraform output (infra/jenkins/jenkins.yaml), so this
        // pipeline is not pinned to one environment and one IP.
        SSH_OPTS = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build') {
            steps {
                sh 'mvn -B -DskipTests package'
            }
        }

        stage('Test') {
            steps {
                sh 'mvn -B test'
            }
            post {
                always {
                    junit testResults: 'target/surefire-reports/*.xml', allowEmptyResults: true
                }
            }
        }

        stage('Containerize') {
            steps {
                sh 'docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" .'
            }
        }

        stage('Security Scan') {
            steps {
                // Two passes, because "report everything" and "block a release"
                // are different jobs and one flag cannot do both.
                //
                // Pass 1 reports HIGH and MEDIUM without failing: useful to see,
                // not worth stopping a release for at 2 a.m.
                // Pass 2 is the gate. --exit-code 1 means a CRITICAL finding
                // makes the step exit nonzero, and there is no `|| true` to
                // swallow it -- the stage, and the build, go red.
                //
                // --ignore-unfixed on the gate is deliberate: gating on findings
                // with no available fix would block every release on something
                // nobody can act on, and a gate people learn to bypass is worse
                // than no gate. Unfixed criticals still show in pass 1.
                sh 'trivy image --download-db-only --timeout 10m'

                sh '''
                    trivy image \
                        --scanners vuln \
                        --severity CRITICAL,HIGH,MEDIUM \
                        --exit-code 0 \
                        --no-progress \
                        --format table \
                        --output trivy-report.txt \
                        "${IMAGE_NAME}:${IMAGE_TAG}"
                    echo "--- Trivy report (informational) ---"
                    cat trivy-report.txt
                '''

                sh '''
                    echo "--- Trivy gate: CRITICAL findings fail this build ---"
                    trivy image \
                        --scanners vuln \
                        --severity CRITICAL \
                        --ignore-unfixed \
                        --exit-code 1 \
                        --no-progress \
                        "${IMAGE_NAME}:${IMAGE_TAG}"
                '''

                // The other half of "no secrets in the pipeline": prove none
                // came back. See scripts/check-no-hardcoded-secrets.sh.
                sh './scripts/check-no-hardcoded-secrets.sh'
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Deploy') {
            steps {
                // Gap 2 of 3 closed. The password that used to be typed into
                // this file is gone; authentication is an SSH key held in the
                // Jenkins credential store and referenced only by its id.
                // sshagent puts the key in an agent for the duration of the
                // block -- it is never written to the workspace, never echoed,
                // and never appears in the build log.
                //
                // The credential is declared in infra/jenkins/jenkins.yaml, so
                // "which secrets does this pipeline need" is answerable from the
                // repo instead of from someone's memory of the Jenkins UI.
                sshagent(credentials: ['kente-deploy-ssh']) {
                    sh '''
                        set -eu

                        # No registry in this environment, so ship the image over
                        # the same SSH connection. One less credential to hold and
                        # one less service to pay for; see docs/assumptions-log.md
                        # for when this stops being the right call.
                        echo "shipping ${IMAGE_NAME}:${IMAGE_TAG} to ${DEPLOY_HOST}"
                        docker save "${IMAGE_NAME}:${IMAGE_TAG}" \
                            | gzip -1 \
                            | ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" 'gunzip | docker load'

                        ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" "
                            docker rm -f order-service 2>/dev/null || true
                            docker run -d --name order-service --restart unless-stopped \
                                -p 8080:8080 '${IMAGE_NAME}:${IMAGE_TAG}'
                        "
                    '''
                }
            }
        }
    }

    post {
        failure {
            echo "Pipeline failed at stage: ${env.STAGE_NAME}"
        }
    }
}
