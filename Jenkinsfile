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

        stage('Install & Test') {
            steps {
                sh '''
                        npm ci
                '''
            }
        }

        stage('Build Image') {
            steps {
                sh "docker build -t ${FULL_IMAGE} -t ${LATEST_IMAGE} ."
                sh "trivy image ${FULL_IMAGE}"

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
                color: 'sucess',
                message: " *${env.JOB_NAME}* build #${env.BUILD_NUMBER} succed."
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
    }
}
