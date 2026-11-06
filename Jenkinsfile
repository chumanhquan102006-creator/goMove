// GoMove — classroom demo CI/CD on Windows + Docker Desktop.
// This pipeline is intentionally limited to a separate Compose project.
pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 90, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    environment {
        M572_OSRM_DATA_DIR = 'D:\\GoMove-routing'
        M572_SECRET_DIR    = 'D:\\GoMove-Jenkins-private'
        DEMO_PROJECT       = 'gomove-jenkins-demo'
        DEMO_IMAGE         = 'gomove-jenkins-demo-backend:local'
    }

    stages {
        stage('01 Checkout') {
            steps {
                checkout scm
                bat 'git rev-parse --short HEAD'
            }
        }

        stage('02 Restore') {
            steps {
                dir('backend') {
                    bat 'call mvnw.cmd -B -ntp dependency:go-offline'
                }
                dir('mobile') {
                    bat 'flutter pub get --enforce-lockfile'
                }
            }
        }

        stage('03 Validate') {
            steps {
                bat 'docker info --format "Docker: {{.OSType}}/{{.Architecture}}"'
                dir('mobile') {
                    bat 'flutter analyze --no-pub'
                }
                bat 'docker compose -p %DEMO_PROJECT% -f compose.m572.yaml -f compose.jenkins-demo.yaml config --quiet'
            }
        }

        stage('04 Unit Test') {
            steps {
                dir('mobile') {
                    bat 'flutter test --no-pub'
                }
            }
        }

        stage('05 Integration Test') {
            steps {
                dir('backend') {
                    // Includes the backend unit and PostGIS Testcontainers tests.
                    bat 'call mvnw.cmd -B -ntp clean test'
                }
            }
        }

        stage('06 Build JAR') {
            steps {
                dir('backend') {
                    bat 'call mvnw.cmd -B -ntp -DskipTests package'
                }
            }
        }

        stage('07 Docker Build') {
            steps {
                // The repository Dockerfile builds the JAR again in a container.
                bat 'docker build --platform linux/amd64 -f backend/Dockerfile -t %DEMO_IMAGE% backend'
            }
        }

        stage('08 Verify Image') {
            steps {
                bat 'docker image inspect %DEMO_IMAGE% --format "Image: {{.Os}}/{{.Architecture}}"'
            }
        }

        stage('09 Deploy') {
            steps {
                // Never run compose down -v or prune: existing projects remain intact.
                bat 'docker compose -p %DEMO_PROJECT% -f compose.m572.yaml -f compose.jenkins-demo.yaml up -d --no-build --wait --wait-timeout 240'
            }
        }

        stage('10 Smoke Test') {
            steps {
                powershell '''
                    $ErrorActionPreference = 'Stop'
                    $result = Invoke-RestMethod -Uri 'http://127.0.0.1:18082/actuator/health' -TimeoutSec 20
                    if ($result.status -ne 'UP') { throw 'GoMove readiness failed.' }
                    Write-Host 'Backend health UP on localhost:18082'
                '''
                bat 'docker compose -p %DEMO_PROJECT% -f compose.m572.yaml -f compose.jenkins-demo.yaml ps'
            }
        }
    }

    post {
        always {
            junit allowEmptyResults: true, testResults: 'backend/target/surefire-reports/*.xml'
        }
    }
}
