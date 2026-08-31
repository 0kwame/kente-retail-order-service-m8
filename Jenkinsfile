// Kente Retail -- order-service pipeline.
//
// STATUS: partially working. It builds, tests, and containerizes the
// service, but it does not meet the brief yet -- see the TODO(learner)
// comments below for the three gaps you need to close:
//   1. CLOSED -- Security Scan now gates on CRITICAL findings.
//   2. CLOSED -- Deploy authenticates with a Jenkins SSH credential.
//   3. CLOSED -- blue-green deploy, nginx traffic switch, and an automatic
//      rollback if the build fails after traffic has moved.
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

        stage('Deploy (idle colour)') {
            // Feature branches build, test and scan but never touch the deploy
            // target. The two broken/* branches are supposed to die above this
            // line, which is the whole point of them.
            when { branch 'main' }
            steps {
                sshagent(credentials: ['kente-deploy-ssh']) {
                    script {
                        // Ask the target which colour is live rather than
                        // tracking it in Jenkins. Jenkins can be rebuilt; the
                        // nginx upstream file is the truth either way.
                        env.LIVE_COLOUR = sh(returnStdout: true, script:
                            'ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" sudo /usr/local/bin/bluegreen.sh current').trim()
                        env.IDLE_COLOUR = sh(returnStdout: true, script:
                            'ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" sudo /usr/local/bin/bluegreen.sh idle').trim()
                        env.IDLE_PORT = sh(returnStdout: true, script:
                            'ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" sudo /usr/local/bin/bluegreen.sh port ${IDLE_COLOUR}').trim()
                        echo "live=${env.LIVE_COLOUR}  deploying to idle=${env.IDLE_COLOUR} on port ${env.IDLE_PORT}"
                    }

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

                        # bluegreen.sh refuses to deploy onto the live colour, so
                        # the not-blue-green path is closed on the target too, not
                        # just by convention here.
                        ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" \
                            "sudo /usr/local/bin/bluegreen.sh deploy ${IDLE_COLOUR} ${IMAGE_NAME}:${IMAGE_TAG}"

                        # Smoke the new colour BEFORE any traffic reaches it. A
                        # build that gets this far and fails here has cost the
                        # customer nothing.
                        ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" \
                            "/usr/local/bin/smoke.sh http://127.0.0.1:${IDLE_PORT}"
                    '''
                }
            }
        }

        stage('Switch Traffic') {
            when { branch 'main' }
            steps {
                script {
                    // Set before the switch, not after: if the switch half-fails,
                    // post{failure} still needs to know traffic may have moved.
                    env.SWITCH_ATTEMPTED = 'true'
                }
                sshagent(credentials: ['kente-deploy-ssh']) {
                    sh '''
                        set -eu
                        ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" \
                            "sudo /usr/local/bin/bluegreen.sh switch ${IDLE_COLOUR}"
                    '''
                }

                // Smoke through nginx from the Jenkins host -- an outside-the-box
                // check that the switch actually moved customer traffic, not just
                // that a container is healthy on localhost.
                sh './deploy/smoke.sh http://${DEPLOY_HOST}'
            }
        }

        stage('Verify') {
            when { branch 'main' }
            steps {
                sshagent(credentials: ['kente-deploy-ssh']) {
                    sh 'ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" sudo /usr/local/bin/bluegreen.sh status'
                }
                echo "${env.IDLE_COLOUR} is live with ${env.IMAGE_NAME}:${env.IMAGE_TAG}. " +
                     "${env.LIVE_COLOUR} is still running and one reload away if this goes wrong."
            }
        }
    }

    post {
        failure {
            script {
                if (env.SWITCH_ATTEMPTED == 'true') {
                    echo 'Traffic had already been switched when this build failed -- rolling back.'
                    // A rollback that throws must not mask the original failure,
                    // and must not stop the notification below from going out.
                    try {
                        sshagent(credentials: ['kente-deploy-ssh']) {
                            sh 'ssh ${SSH_OPTS} "deploy@${DEPLOY_HOST}" sudo /usr/local/bin/bluegreen.sh rollback'
                        }
                        echo 'Rollback complete.'
                    } catch (err) {
                        echo "ROLLBACK FAILED -- the target needs a human now: ${err}"
                    }
                } else {
                    echo 'Failed before any traffic moved. Nothing to roll back.'
                }
            }
        }
    }
}
