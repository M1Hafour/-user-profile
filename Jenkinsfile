pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '3'))
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        REGISTRY            = 'docker.io/mohamedhafour'
        IMAGE_NAME           = 'user-profile-app'
        IMAGE_TAG             = "${env.GIT_COMMIT.take(7)}"
        FULL_IMAGE            = "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        LATEST_IMAGE          = "${REGISTRY}/${IMAGE_NAME}:latest"

        DOCKERHUB_CREDS      = credentials('dockerhub-creds')
        MONGO_CREDS          = credentials('mongo-creds')
        APP_ENV               = credentials('user-profile-app-env')
    }

    stages {

        stage('Install') {
            steps {
                script {
                    def lockHash = sh(script: "sha256sum package-lock.json 2>/dev/null | cut -d' ' -f1 || echo none", returnStdout: true).trim()
                    env.CACHE_DIR = "${JENKINS_HOME}/npm-cache/${lockHash}"
                }
                sh '''
                    if [ -f package.json ]; then
                        if [ -d "$CACHE_DIR" ]; then
                            echo "Cache hit — reusing node_modules for this lockfile"
                            cp -a "$CACHE_DIR" ./node_modules
                        else
                            npm ci
                            mkdir -p "$(dirname "$CACHE_DIR")"
                            cp -a ./node_modules "$CACHE_DIR"
                        fi
                    fi
                '''
            }
        }

        stage('Test & Coverage') {
            steps {
                sh '''
                    if [ -f package.json ]; then
                        if npx --yes jest --version >/dev/null 2>&1; then
                            npx jest --coverage --ci || true
                        else
                            npm test --if-present
                        fi
                    fi
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'coverage/**', allowEmptyArchive: true
                    junit testResults: 'junit.xml', allowEmptyResults: true
                }
            }
        }

        stage('Code Scan (ESLint)') {
            steps {
                sh 'npx --yes eslint . --format stylish || true'
            }
        }

        stage('Dependency Audit') {
            steps {
                sh 'npm audit --audit-level=high || true'
            }
        }

        stage('Build Image') {
            steps {
                sh "docker build -t ${FULL_IMAGE} -t ${LATEST_IMAGE} ."
            }
        }

        stage('Docker Image Scan') {
            steps {
                sh "trivy image --timeout 15m --severity HIGH,CRITICAL --exit-code 1 ${FULL_IMAGE}"
            }
        }

        stage('Push Image') {
            steps {
                sh '''
                    echo "$DOCKERHUB_CREDS_PSW" | docker login -u "$DOCKERHUB_CREDS_USR" --password-stdin
                    docker push ${FULL_IMAGE}
                    docker push ${LATEST_IMAGE}
                '''
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                    cp "$APP_ENV" .env
                    export MONGO_USERNAME="$MONGO_CREDS_USR"
                    export MONGO_PASSWORD="$MONGO_CREDS_PSW"
                    docker compose pull || true
                    docker compose up -d --remove-orphans
                    docker image prune -f
                '''
            }
        }
    }

    post {
        success {
            echo "Deployed ${FULL_IMAGE} successfully."
            slackSend(
                channel: '#jenkins',
                color: 'good',
                message: "✅ *${env.JOB_NAME}* build #${env.BUILD_NUMBER} succeeded."
            )
        }
        failure {
            echo "Pipeline failed — check the stage logs above."
            slackSend(
                channel: '#jenkins',
                color: 'danger',
                message: "❌ *${env.JOB_NAME}* build #${env.BUILD_NUMBER} failed.\n<${env.BUILD_URL}|View console output>"
            )
        }
        always {
            sh 'docker logout || true'
        }
    }
}
