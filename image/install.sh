#!/bin/bash -e

# Copyright 2015 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

function showUsage() {
  local shell_name=`basename $0`
  cat << EOF
Usage: $shell_name [--project PROJECT] [--cpu CPU] [--memory MEMORY] [--disk DISK]
                  [--build_from_src] [--use_test_img] [--on_conflict_restore_from_backup]
       --project PROJECT
           Sets the Google Cloud project you want to deploy to. PROJECT is the id
           of the project. If this option is not provided, default to the current
           project in gcloud config.
       --cpu CPU
           The number of CPUs to use. Minium CPU is 1, default is 4.
       --memory MEMORY
         Memory in GB. Minimum is 4(GB), default is 8(GB).
       --disk DISK
         Both memory size and disk sizes are in GB. Minimum is 200(GB), default is 200(GB)
       --build_from_src
         Build the image from your local source code. The default value is false so it
         will use a pre-built image 'gcr.io/developer_tools_bundle/jenkins'.
         If on your machine docker must be run as root user, you will be prompted for
         root password by 'sudo docker ...'.
       --use_test_img
         Deploy using the test version Google pre-built Docker image.
       --report_usage
         Enable anonymized usage reports. Jenkins usage information will be sent to
         Google via the Google Usage Reporting plugin. This is a project-wide setting.
       --on_conflict_restore_from_backup
         On Jenkins restart after upgrade, backup changes will overwrite disk changes if you use this flag.
	 This means, pre-installed Jenkins settings/plugins may not work. 
         Regular jenkins restart(non upgrades) will still favour backup changes
         so user configurations are not lost. This is a project-wide setting and will default to false. 
       Omit cpu/memory/disk/on_conflict_restore_from_backup options to use default value.

       Example: $shell_name --project my_project_id --cpu 3 --memory 6
EOF
  exit
}

function verifyAgainstMinimum() {
  local minimum=$1
  local default=$2
  local var=$3
  if [[ -z $var ]]; then
    printf "$default"
  elif (( $(echo "$var < $minimum" | bc -l) )); then
    printf "$minimum"
  else
    printf "$var"
  fi
}

DEPLOY_FLAVOR=stable
function parseArguments() {
  SHOW_USAGE=false
  RESTORE_FROM_BACKUP=false
  SEND_USAGE_REPORTS=false
  
  while [[ -n "$1" ]]; do
    case $1 in
      --project)
        if [[ $2 != ""  && ${2:0:1} != "-" ]]; then
          TARGET_PROJECT=$2 && shift
        fi
        ;;
      --cpu)
        if [[ $2 != ""  && ${2:0:1} != "-" ]]; then
          JENKINS_CPU=$2 && shift
        fi
        ;;
      --memory)
        if [[ $2 != ""  && ${2:0:1} != "-" ]]; then
          JENKINS_MEMORY=$2 && shift
        fi
        ;;
      --disk)
        if [[ $2 != ""  && ${2:0:1} != "-" ]]; then
          JENKINS_DISK=$2 && shift
        fi
        ;;
      --build_from_src)
        BUILD_FROM_SRC=true
        DEPLOY_FLAVOR=local_version
        ;;
      --use_test_img)
        USE_TEST_IMG=true
        DEPLOY_FLAVOR=testing
        ;;
      --report_usage)
	SEND_USAGE_REPORTS=true
        ;;
      --on_conflict_restore_from_backup)
        RESTORE_FROM_BACKUP=true
	;;
      -h|--help|*)
        SHOW_USAGE=true
        break
        ;;
    esac
    shift
  done
  if [[ $SHOW_USAGE = true ]]; then
    showUsage $0
    exit
  else
    JENKINS_CPU=$(verifyAgainstMinimum 1 4 $JENKINS_CPU)
    JENKINS_MEMORY=$(verifyAgainstMinimum 4 8 $JENKINS_MEMORY)
    JENKINS_DISK=$(verifyAgainstMinimum 200 200 $JENKINS_DISK)
  fi
}

function defaultModuleExists() {
  local project=$1
  local count=$(gcloud --quiet preview app modules list default --project $project 2>&1 \
    | grep -o "^default" | wc -l)
  if [[ $count -gt 0 ]]; then
    return 0
  else
    return 1
  fi
}

function deployDefaultModule() {
  local target_project=$1
  local tmp_dir=$(mktemp -d --tmpdir=$(pwd))
  echo
  echo "Default module doesn't exist, deploying default module now..."
  cat > ${tmp_dir}/app.yaml <<EOF
module: default
runtime: python27
api_version: 1
threadsafe: true
handlers:
- url: /
  mime_type: text/html
  static_files: hello.html
  upload: (.*html)
EOF

  cat > ${tmp_dir}/hello.html <<EOF
<html>
  <head>
    <title>Sample Hello-World Page.</title>
  </head>
  <body>
    Hello, World!
  </body>
</html>
EOF
  local status=1
  gcloud --quiet preview app deploy --force --project $target_project \
    $tmp_dir/app.yaml --version v1
  [[ $? ]] && succeeded=0 || echo "Failed to deploy default module to $target_project"
  rm -rf $tmp_dir
  return $succeeded
}

function networkExists() {
  local project=$1
  local network=$2
  gcloud --quiet compute networks list $network --project $project --format yaml \
    | grep "^name:\s*$network$" > /dev/null 2>&1
  return $?
}

function createAppDotYaml() {
  local tmp_dir=$1
  local jenkins_cpu=$2
  local jenkins_memory=$3
  local jenkins_disk=$4
  cat > ${tmp_dir}/app.yaml<<EOF
module: jenkins
runtime: custom
vm: true
api_version: 1
threadsafe: on

manual_scaling:
  instances: 1

resources:
  cpu: $jenkins_cpu
  memory_gb: $jenkins_memory
  disk_size_gb: $jenkins_disk

beta_settings:
  # This grants API access to the service account associated with the instance.
  # Add or remove scopes here to change the permissions given to the service
  # account.
  service_account_scopes: https://www.googleapis.com/auth/projecthosting,https://www.googleapis.com/auth/gerritcodereview,https://www.googleapis.com/auth/devstorage.full_control,https://www.googleapis.com/auth/appengine.admin
  # This enables docker images nested within docker images; Jenkins setup will
  # fail without this line.
  run_docker_privileged: true

builtins:
- appstats: on

health_check:
  enable_health_check: True
  check_interval_sec: 10
  timeout_sec: 4
  unhealthy_threshold: 2
  healthy_threshold: 2
  restart_threshold: 60

network:
  name: jenkins

handlers:

# Favicon.  Without this, the browser hits this once per page view.
- url: /favicon.ico
  static_files: favicon.ico
  upload: favicon.ico

# Allow access to the github webhook
- url: /github-webhook.*
  script: main.application

# Main app.  All the real work is here.
- url: /.*
  script: main.application
  login: admin
  secure: always
EOF
}

function buildLocalImg() {
  local img=$1
  local img_upload=$2
  if groups $USER | grep &>/dev/null '\bdocker\b'; then
    docker build -t $img . && docker tag -f $img $img_upload \
      && gcloud --quiet docker push $img_upload
  else
    sudo docker build -t $img . && sudo docker tag -f $img $img_upload \
      && gcloud --quiet docker push $img_upload
  fi
}

function createDockerfile() {
  local tmp_dir=$1
  local img=$2
  cat > ${tmp_dir}/Dockerfile <<EOF
FROM $img
RUN true
EOF
}

function isHealthy() {
  local project=$1
  local module=$2
  local url="https://${module}-dot-${project}.appspot.com/_ah/health"
  local RETRY_MAX_COUNT=500
  echo "Waiting for ${module} to be up and running. May take a while ..."
  for TRY in $(seq 1 $RETRY_MAX_COUNT); do
    local status_code=$(curl -w %{http_code} -s --output /dev/null -L ${url})
    [[ $status_code -eq 200 ]] && return 0
    sleep 1
    [[ $(expr $TRY % 50) -eq 0 ]] && (printf ".\n") || (printf ".")
  done
  return 1
}

############### _MAIN_ ###############

parseArguments $@

if [[ -z $TARGET_PROJECT ]]; then
  CURRENT_PROJECT=`gcloud --quiet config list project | \
    awk 'BEGIN{FS="="} /project\s*=/ {print $2}' | tr -d '[[:space:]]'`
  TARGET_PROJECT=$CURRENT_PROJECT
fi
if [[ -z $TARGET_PROJECT ]]; then
  echo "There is no project set in your gcloud config, so you must specify the project."
  exit 1
fi
echo "You will deploy the following component to project '$TARGET_PROJECT'"
echo "  Jenkins: CPU-$JENKINS_CPU, Memory-${JENKINS_MEMORY}GB, Disk-${JENKINS_DISK}GB, On conflict overwrite from backup-${RESTORE_FROM_BACKUP}"
if [[ "$BUILD_FROM_SRC" = true ]]; then
  echo "  Using Docker image built from your local source code."
elif [[ "$USE_TEST_IMG" = true ]]; then
  echo "  Using Google pre-built Docker image (test version)."
else
  echo "  Using Google pre-built Docker image."
fi

if [[ "$SEND_USAGE_REPORTS" = true ]]; then
  echo "  Enabling usage reporting."
else
  echo "  Disabling usage reporting."
fi
read -p "Please confirm [y|N]" YESORNO
if [[ "$YESORNO" != "y" && "$YESORNO" != "Y" ]]; then
  echo "Deployment canceled"
  exit
fi

if [[ "$SEND_USAGE_REPORTS" = true ]]; then
  gcloud --quiet compute project-info add-metadata --metadata google_report_analytics_id=UA-36037335-1,google_report_usage=true --project $TARGET_PROJECT
else
  gcloud --quiet compute project-info remove-metadata --keys google_report_analytics_id,google_report_usage --project $TARGET_PROJECT
fi

if [[ "$RESTORE_FROM_BACKUP" = true ]]; then
  gcloud --quiet compute project-info add-metadata --metadata restore_from_backup=true --project $TARGET_PROJECT
else
  gcloud --quiet compute project-info remove-metadata --keys restore_from_backup --project $TARGET_PROJECT
fi

echo
echo "**********************************************************************"
echo "* Now deploying ..."
echo "**********************************************************************"
if ! defaultModuleExists $TARGET_PROJECT; then
  if ! deployDefaultModule $TARGET_PROJECT; then
    exit
  fi
fi

BUILD_DIR=tmp_build_dir
PRE_BUILD_IMG="gcr.io/developer_tools_bundle/jenkins"
PRE_BUILD_IMG_TEST="gcr.io/developer_tools_bundle/jenkins:testing"
UPLOADED_LOCAL_BUILD_IMG="gcr.io/"${TARGET_PROJECT}"/jenkins:local_version"

if ! networkExists $TARGET_PROJECT jenkins; then
  gcloud --quiet compute networks create jenkins --project $TARGET_PROJECT \
    --range 10.240.0.0/16
  if [ $? -ne 0 ]; then
    echo
    echo "*** 'gcloud compute networks create jenkins' failed. ***"
    exit
  fi
fi

BUILD_DIR=tmp_build_dir
DEPLOY_DIR=${BUILD_DIR}/deploy_${DEPLOY_FLAVOR}
rm -rf $DEPLOY_DIR
mkdir -p $DEPLOY_DIR
createAppDotYaml $DEPLOY_DIR $JENKINS_CPU $JENKINS_MEMORY $JENKINS_DISK
if [[ "$BUILD_FROM_SRC" = true ]]; then
  ./build.sh local_version --project $TARGET_PROJECT --push_image
  if [[ $? -ne 0 ]]; then
    echo "Failed to build/push image from local source file."
    exit 1
  fi
  createDockerfile $DEPLOY_DIR $UPLOADED_LOCAL_BUILD_IMG
elif [[ "$USE_TEST_IMG" = true ]]; then
  createDockerfile $DEPLOY_DIR $PRE_BUILD_IMG_TEST
else
  createDockerfile $DEPLOY_DIR $PRE_BUILD_IMG
fi

gcloud --quiet preview app deploy --docker-build=remote --force $DEPLOY_DIR/app.yaml --project $TARGET_PROJECT \
  --version v1 --set-default
if isHealthy $TARGET_PROJECT jenkins; then
  echo
  echo "*** Jenkins successfully deployed! ***"
  echo
else
  echo
  echo "*** Jenkins deployment may have failed! ***"
  echo
fi
