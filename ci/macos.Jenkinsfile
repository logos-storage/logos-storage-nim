#!/usr/bin/env groovy
library 'status-jenkins-lib@v1.9.37'

pipeline {
  agent { label 'macos && aarch64 && nix' }

  options {
    timestamps()
    ansiColor('xterm')
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
    disableRestartFromStage()
    /* manage how many builds we keep */
    buildDiscarder(logRotator(
      numToKeepStr: '20',
      daysToKeepStr: '30',
    ))
    /* Checkout is done in the Checkout stage with full history. */
    skipDefaultCheckout()
  }

  stages {
    stage('Checkout') {
      steps {
        script {
          /* Nix needs revCount for every submodule, which a shallow clone
           * cannot provide, so clone with full history like fetch-depth: 0. */
          checkout scmGit(
            branches: scm.branches,
            userRemoteConfigs: scm.userRemoteConfigs,
            extensions: scm.extensions.findAll {
              !(it instanceof hudson.plugins.git.extensions.impl.CloneOption) &&
              !(it instanceof hudson.plugins.git.extensions.impl.SubmoduleOption)
            } + [
              cloneOption(shallow: false, noTags: false),
              submodule(
                recursiveSubmodules: true,
                parentCredentials: true,
                shallow: false,
              ),
            ],
          )
        }
      }
    }

    stage('Build') {
      steps {
        script {
          nix.flake("default")
        }
      }
    }

    stage('Check') {
      steps {
        script {
          sh './result/bin/storage --version'
        }
      }
    }
  }

  post {
    cleanup {
      cleanWs()
      dir(env.WORKSPACE_TMP) { deleteDir() }
    }
  }
}
