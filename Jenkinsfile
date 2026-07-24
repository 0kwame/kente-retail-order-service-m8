// Kente Retail -- order-service pipeline.
//
// STATUS: partially working. It builds, tests, and containerizes the
// service, but it does not meet the brief yet -- see the TODO(learner)
// comments below for the three gaps you need to close:
//   1. Security Scan never fails the build, no matter what Trivy finds.
//   2. Deploy authenticates with a password typed directly into this file.
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
        DEPLOY_HOST = "10.0.2.20" // TODO(learner): point this at your real deployment target
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
                // TODO(learner): --exit-code 0 means this step always "succeeds"
                // regardless of what Trivy finds, and the `|| true` on top of that
                // swallows even a nonzero exit if you change the flag. The CTO
                // wants critical vulnerabilities to actually stop the pipeline --
                // fix both of these.
                sh 'trivy image --severity CRITICAL,HIGH --exit-code 0 "${IMAGE_NAME}:${IMAGE_TAG}" || true'
            }
        }

        stage('Deploy') {
            steps {
                // TODO(learner): this is exactly the kind of hardcoded credential
                // the brief says must never ship -- '***REMOVED***' is typed right
                // here in plain text. Replace this with a Jenkins credential
                // (withCredentials / sshagent, referenced by credentialsId) before
                // this pipeline is "done."
                //
                // TODO(learner): this also deploys straight over the one running
                // container. The brief asks for blue-green with a demonstrated
                // rollback -- there is no second (green) environment and no
                // traffic-switch step here yet.
                sh """
                    sshpass -p '***REMOVED***' ssh -o StrictHostKeyChecking=no deploy@${DEPLOY_HOST} '
                        docker pull ${IMAGE_NAME}:${IMAGE_TAG} &&
                        docker rm -f order-service || true &&
                        docker run -d --name order-service -p 8080:8080 ${IMAGE_NAME}:${IMAGE_TAG}
                    '
                """
            }
        }
    }

    post {
        failure {
            echo "Pipeline failed at stage: ${env.STAGE_NAME}"
        }
    }
}
