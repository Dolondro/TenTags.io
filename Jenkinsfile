pipeline {
  agent any
  stages {
    stage('build docker') {
      steps {
        sh '''
touch filtta.env
./tentags buildtest
./tentags test'''
      }
    }
    stage('publish coverage') {
      parallel {
        stage('publish coverage') {
          steps {
            cobertura(autoUpdateHealth: true, autoUpdateStability: true, coberturaReportFile: 'api-cdn/luacov.reports.out', failNoReports: true)
          }
        }
      }
    }
  }
  post {
        always {
            junit './api-cdn/test.xml'
        }
    }
}