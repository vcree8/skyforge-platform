/*
 * Unit 4 - Cloud Computing and DevOps  -  OTHM K/650/7997
 * Artefact P4.3   Assessment criteria: AC 1.1, 1.3
 * Jenkins declarative pipeline - equivalent toolchain on a self-hosted runner
 * 
 * Vera Cree  |  Candidate 240301062  |  CIPS Centre DC2401845
 */

pipeline {
    agent { label 'docker' }

    environment {
        AWS_REGION  = 'eu-west-2'
        ECR         = '123456789012.dkr.ecr.eu-west-2.amazonaws.com'
        IMAGE       = "${ECR}/skyforge/platform:${env.GIT_COMMIT.take(8)}"
    }
    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }
    triggers { githubPush() }               // AC 1.1 - version control integration

    stages {
        stage('Checkout')  { steps { checkout scm } }

        stage('Build')     { steps { sh 'mvn -B clean package -DskipTests' } }

        stage('Test') {
            steps { sh 'mvn -B verify' }
            post  { always { junit 'target/surefire-reports/*.xml'
                             jacoco execPattern: 'target/jacoco.exec' } }
        }

        stage('Quality gates') {           // run in parallel to cut lead time
            parallel {
                stage('SAST')      { steps { sh 'semgrep --config p/owasp-top-ten --error .' } }
                stage('SCA')       { steps { sh 'mvn dependency-check:check -DfailBuildOnCVSS=7' } }
                stage('Terraform') { steps { sh 'tfsec ./terraform' } }
            }
        }

        stage('Image') {
            steps {
                sh """
                   aws ecr get-login-password --region ${AWS_REGION} \
                     | docker login --username AWS \
                                    --password-stdin ${ECR}
                   docker build -f docker/Dockerfile -t ${IMAGE} .
                   trivy image --exit-code 1 --severity HIGH,CRITICAL ${IMAGE}
                   docker push ${IMAGE}
                """
            }
        }

        stage('Deploy to staging') {
            steps {
                sh """
                   aws eks update-kubeconfig --name skyforge-eks-staging
                   kubectl set image deployment/skyforge-api api=${IMAGE} -n staging
                   kubectl rollout status deployment/skyforge-api -n staging --timeout=5m
                """
            }
        }

        stage('Approve production') {
            steps { timeout(time: 24, unit: 'HOURS') {
                input message: 'Promote to production?', submitter: 'platform-leads' } }
        }

        stage('Deploy to production') {
            steps {
                sh """
                   aws eks update-kubeconfig --name skyforge-eks-prod
                   kubectl set image deployment/skyforge-api api=${IMAGE} -n production
                   kubectl rollout status deployment/skyforge-api -n production --timeout=5m
                """
            }
        }
    }
    post {
        failure { slackSend channel: '#platform-alerts',
                            message: "FAILED ${env.JOB_NAME} #${env.BUILD_NUMBER}" }
        success { slackSend channel: '#platform-deploys',
                            message: "Deployed ${IMAGE}" }
    }
}
