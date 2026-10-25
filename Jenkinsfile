pipeline {
    agent any

    stages {
        stage('Build Artifact') {
            steps {
                sh 'mvn clean verify'
                archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
            }
        }

        stage('Unit Tests - JUnit and JaCoCo') {
            steps {
                echo 'Publishing JUnit test results and JaCoCo coverage'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
                    jacoco execPattern: 'target/jacoco.exec'
                }
            }
        }

        stage('Vulnerability Scan - Docker') {
            parallel {
                stage('OWASP Dependency-Check') {
                    steps {
                        withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
                            sh '''
                                mvn org.owasp:dependency-check-maven:12.1.0:check \
                                  -DnvdApiKey="$NVD_API_KEY" \
                                  -DossindexAnalyzerEnabled=false
                            '''
                        }
                    }
                    post {
                        always {
                            dependencyCheckPublisher pattern: 'target/dependency-check-report.xml'
                        }
                    }
                }

                stage('Trivy Image Scan') {
                    steps {
                        sh 'bash trivy-docker-image-scan.sh'
                    }
                }

                stage('OPA Conftest') {
                    steps {
                        sh 'docker run --rm -v "$(pwd):/project" openpolicyagent/conftest test --policy docker-security.rego Dockerfile'
                    }
                }
            }
        }

        stage('Docker Build and Push') {
            steps {
                withDockerRegistry(credentialsId: 'docker-hub-pass', url: '') {
                    sh 'docker build -t adityalokapalli309/numeric-app:${GIT_COMMIT} .'
                    sh 'docker push adityalokapalli309/numeric-app:${GIT_COMMIT}'
                }
            }
        }

        stage('Kubernetes Deployment - DEV') {
            steps {
                withKubeConfig([credentialsId: 'kubeconfig']) {
                    sh '''
                        kubectl set image deployment/node-app \
                          numeric-app=adityalokapalli309/numeric-app:${GIT_COMMIT}
                        kubectl rollout status deployment/node-app
                    '''
                }
            }
        }

        stage('Check Java Environment') {
            steps {
                sh 'java -version'
                sh 'mvn -version'
                sh 'echo $JAVA_HOME'
            }
        }

        stage('Mutation Tests - PIT') {
            steps {
                sh 'mvn test-compile org.pitest:pitest-maven:mutationCoverage'
            }
            post {
                always {
                    pitmutation mutationStatsFile: '**/target/pit-reports/**/mutations.xml'
                }
            }
        }

        stage('SonarQube - SAST') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh '''
                        mvn org.sonarsource.scanner.maven:sonar-maven-plugin:5.3.0.6276:sonar \
                          -Dsonar.projectKey=numeric-app \
                          -Dsonar.projectName=numeric-app
                    '''
                }
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed.'
        }
    }
}