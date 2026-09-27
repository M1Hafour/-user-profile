pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        REGISTRY            = 'docker.io/mohamedhafour'          
        IMAGE_NAME           = 'user-profile-app'
        IMAGE_TAG             = "${env.BUILD_NUMBER}"
        FULL_IMAGE            = "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        LATEST_IMAGE          = "${REGISTRY}/${IMAGE_NAME}:latest"

        DOCKERHUB_CREDS      = credentials('dockerhub-creds')     // username/password
        MONGO_CREDS          = credentials('mongo-creds')         // username/password (secret text pair)
        APP_ENV               = credentials('user-profile-app-env')       // "Secret file" credential containing a .env
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Install & Test') {
            steps {
                sh '''
                    docker run --rm \
                        -v "$PWD":/app -w /app \
                        node:20-alpine \
                        sh -c "if [ -f package.json ]; then npm ci && npm test --if-present; fi"
                '''
		}
        }

        stage('Build Image') {
            steps {
                sh "docker build -t ${FULL_IMAGE} -t ${LATEST_IMAGE} ."
            }
        }


        stage('Push Image') {
            when { expression { return env.REGISTRY?.trim() } }
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
                withCredentials([file(credentialsId: 'app-env-file', variable: 'ENV_FILE')]) {
                    sh '''
                        cp "$ENV_FILE" .env
                        export MONGO_USERNAME="$MONGO_CREDS_USR"
                        export MONGO_PASSWORD="$MONGO_CREDS_PSW"
                        docker compose pull --ignore-pull-failures || true
                        docker compose up -d --remove-orphans
                        docker image prune -f
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Deployed ${FULL_IMAGE} successfully."
        }
        failure {
            echo "Pipeline failed — check the stage logs above."
        }
    }
}
