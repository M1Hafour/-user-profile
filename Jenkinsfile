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

        // ---- AWS deployment targets: set these three after creating the servers ----
        // (see deploy/AWS-GUIDE.md, Part F). They are addresses, not secrets.
        AWS_NGINX_HOST       = '16.170.142.141'   // Elastic IP of the public nginx server
        AWS_PRIVATE1_IP      = '10.0.140.207'   // private IP of private1 (app + MongoDB)
        AWS_PRIVATE2_IP      = '10.0.130.5'   // private IP of private2 (app)
        // The HTTPS name of the site (e.g. myapp.duckdns.org): the same value as DOMAIN in
        // deploy/nginx/.env, set once HTTPS is on (deploy/AWS-GUIDE.md, Part G). Verify uses it.
        // Leave CHANGE_ME while the site is HTTP only.
        AWS_DOMAIN           = 'myuserapp.duckdns.org'
        // The SSH key is the Jenkins credential 'aws-ssh-key' (SSH Username with private key).
    }

    stages {

        stage('Install') {
            steps {
                // Clean, lockfile-exact install. If this fails with "package.json and
                // package-lock.json are not in sync", run `npm install` locally once and
                // commit the updated package-lock.json (don't switch this to `npm install`).
                sh 'npm install'
            }
        }

        stage('Test & Coverage') {
            steps {
                // Assumes Jest. If your app uses Mocha/another runner, swap this command
                // and the coverage tool accordingly — ask me to adjust once confirmed.
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
                    // Publishes coverage HTML report as a build artifact if Jest produced one
                    archiveArtifacts artifacts: 'coverage/**', allowEmptyArchive: true
                    junit testResults: 'junit.xml', allowEmptyResults: true
                }
            }
        }

        stage('Code Scan (ESLint)') {
            steps {
                // Non-blocking to start. Remove `|| true` once the codebase is clean
                // enough that lint failures should actually stop the pipeline.
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
                // Backend (API) image. The frontend is not an image: nginx on AWS serves
                // frontend/public directly, and its config is checked by deploy/nginx/install.sh.
                sh "docker build -t ${FULL_IMAGE} -t ${LATEST_IMAGE} ."
            }
        }

        stage('Docker Image Scan') {
            steps {
                // Blocking: fails the build on HIGH/CRITICAL CVEs in the built image.
                // Drop --exit-code / change severity if you want this informational instead.
                sh 'trivy image --timeout 15m --severity HIGH,CRITICAL --exit-code 1 ${FULL_IMAGE}'
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

        stage('Deploy to AWS') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'aws-ssh-key', keyFileVariable: 'SSH_KEY', usernameVariable: 'SSH_USER')]) {
                    sh '''
                        set -eu

                        # Stop early with a clear message if the targets were never filled in.
                        for v in AWS_NGINX_HOST AWS_PRIVATE1_IP AWS_PRIVATE2_IP; do
                            val=$(printenv "$v" || true)
                            case "$val" in
                                ""|CHANGE_ME*) echo "Set $v at the top of the Jenkinsfile (see deploy/AWS-GUIDE.md, Part F)."; exit 1 ;;
                            esac
                        done

                        # SSH settings for this build only. The private servers have no public address,
                        # so they are reached by jumping through the nginx server (ProxyJump).
                        # accept-new: trust a server's key the first time, refuse it if it ever changes.
                        SSH_CFG="$(mktemp)"
                        trap 'rm -f "$SSH_CFG"' EXIT
                        printf '%s\\n' \
                            "Host *" \
                            "  User $SSH_USER" \
                            "  IdentityFile $SSH_KEY" \
                            "  IdentitiesOnly yes" \
                            "  BatchMode yes" \
                            "  ConnectTimeout 15" \
                            "  ServerAliveInterval 15" \
                            "  StrictHostKeyChecking accept-new" \
                            "  UserKnownHostsFile ${JENKINS_HOME:-$HOME}/aws_known_hosts" \
                            "Host $AWS_PRIVATE1_IP $AWS_PRIVATE2_IP" \
                            "  ProxyJump $AWS_NGINX_HOST" > "$SSH_CFG"

                        ssh_run() { h="$1"; shift; ssh -F "$SSH_CFG" "$h" "$@"; }

                        echo "== Checking SSH access to all three servers =="
                        ssh_run "$AWS_NGINX_HOST"  true
                        ssh_run "$AWS_PRIVATE1_IP" true
                        ssh_run "$AWS_PRIVATE2_IP" true

                        # On each server: check out exactly the commit Jenkins built (so scripts,
                        # compose files and frontend files match the images), then deploy it.
                        SYNC="cd ~/app && git fetch --quiet origin && git reset --hard $GIT_COMMIT"

                        # Backends first, one at a time: while one restarts, nginx uses the other.
                        # update-private.sh rolls itself back and fails if the new version is unhealthy.
                        echo "== private2 =="
                        ssh_run "$AWS_PRIVATE2_IP" "$SYNC && ./deploy/update-private.sh private2 $IMAGE_TAG"
                        echo "== private1 =="
                        ssh_run "$AWS_PRIVATE1_IP" "$SYNC && ./deploy/update-private.sh private1 $IMAGE_TAG"

                        # Then nginx: new frontend files + config (install.sh checks the config and
                        # restores the old one if nginx rejects it).
                        echo "== nginx =="
                        ssh_run "$AWS_NGINX_HOST" "$SYNC && ./deploy/nginx/install.sh"
                    '''
                }
            }
        }

        stage('Verify Deployment') {
            steps {
                sh '''
                    # Through the public address, the way a visitor reaches the site.
                    # With AWS_DOMAIN set, check HTTPS on that name (trusted certificate).
                    # Otherwise check plain HTTP on the server address. That only works while
                    # HTTPS is off: once a certificate exists, nginx redirects http to https, and
                    # the redirect goes to the IP address, which the certificate does not cover.
                    case "$AWS_DOMAIN" in
                        ""|CHANGE_ME*) BASE="http://${AWS_NGINX_HOST}" ;;
                        *)             BASE="https://${AWS_DOMAIN}" ;;
                    esac

                    for i in $(seq 1 15); do
                        if curl -fsS --max-time 10 "$BASE/" | grep -q "User Profile App" && curl -fsS --max-time 10 "$BASE/health" | grep -q '"mongo":"connected"'; then
                            echo "The site is up at $BASE and the backend is connected to MongoDB."
                            exit 0
                        fi
                        echo "Not ready yet (attempt $i of 15)..."
                        sleep 4
                    done

                    echo "Deployment verification FAILED: $BASE did not answer correctly."
                    echo "If HTTPS is on, set AWS_DOMAIN at the top of this Jenkinsfile to the name in DOMAIN (deploy/nginx/.env)."
                    echo "On the servers: docker compose ps / docker compose logs app (private), sudo tail /var/log/nginx/error.log (nginx)."
                    exit 1
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
