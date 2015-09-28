#!/bin/bash -e
# This script builds the Docker image locally, tags it "testing",
# and pushes it to the container registry.

set -e

function showUsage() {
  local shell_name=`basename $0`
  cat << EOF
Usage: $shell_name <testing\|stable\|local_version> [--project PROJECT] [--push_image]
       testing: build testing version Docker images, and tag them as
           gcr.io/developer_tools_bundle/<image_name>:testing
       stable: build stable version of Docker images and tag them as
           gcr.io/developer_tools_bundle/<image_name>:latest
       local_version: build local version of the image, and tag them as
           tagged as gcr.io/${TARGET}/<image_name>:local_version.
           So this requires --project parameter to be provided
       --project PROJECT: only needed when local_version is specified.
           This is the GCP project that you want to deploy to.
       --push: push the images to gcr.io

       If on your machine docker must be run as root user, you will be prompted for
       root password by 'sudo docker ...'.

       You may not be able to push testing|stable version of the images if you don't have
       permission to the gcr.io/developer_tools_bundle repo.
EOF
}

function parseArguments() {
  if [[ $# -lt 1 ]]; then
    showUsage $0
    exit
  fi
  if [[ $1 == "testing" || $1 == "stable" || $1 == "local_version" ]]; then
    BUILD_TYPE=$1
  else
    showUsage $0
    exit
  fi
  shift 1
  PUSH_IMG=false
  while [[ -n "$1" ]]; do
    case $1 in
      --project)
        if [[ -n "$2" && ${2:0:1} != "-" ]]; then
          TARGET_PROJECT=$2 && shift
        fi
        ;;
      --push_image)
        PUSH_IMG=true
        ;;
      *)
        echo "Unknown argument: $1"
        showUsage $0
        exit 1
        ;;
    esac
    shift
  done
  if [[ $BUILD_TYPE == "local_version" ]]; then
    if [[ -z $TARGET_PROJECT ]]; then
      echo "--project parameter is missing"
      showUsage $0
      exit
    fi
  fi

  if [[ $BUILD_TYPE == "stable" && $PUSH_IMG == "true" ]]; then
    read -p "Please confirm that you are going to push stable images [y|N]" YESORNO
    if [[ "$YESORNO" != "y" && "$YESORNO" != "Y" ]]; then
      echo "Build canceled"
      exit
    fi
  fi
}

BUILD_DIR=tmp_build_dir

function createShellFormat() {
  local result=""
  while [[ -n "$1" ]]; do
    local tmp=`expr "$1" : '\(.*=\)'`
    result=${result}\\\$${tmp::-1},
    shift
  done
  echo $result
}

function createDockerfileFromTemplate() {
  local src_dir=$1
  local build_dir_name=${BUILD_DIR}/$2
  shift 2
  local vars="$@"
  local vars_shell_format=`createShellFormat $vars`

  mkdir -p ${build_dir_name}
  rm -rf ${build_dir_name}/*
  cp -r ${src_dir}/* ${build_dir_name}
  if [[ -z "$vars_shell_format" ]]; then
    # We have to specify some vars in SHELL_FORMAT otherwise envsubst will
    # replace all environment variables in the target file, which is not what we
    # want.
    vars_shell_format=\\\$_NO_VARS_TO_REPLACE_
  fi
  echo "vars_shell_format = $vars_shell_format"
  /bin/bash -c "$vars envsubst $vars_shell_format < ${build_dir_name}/Dockerfile.template > ${build_dir_name}/Dockerfile"
  rm ${build_dir_name}/Dockerfile.template
}

function createSlaveSetupScriptFromTemplate() {
  local build_dir_name=${BUILD_DIR}/$1
  shift 1
  local vars="$@"
  local vars_shell_format=`createShellFormat $vars`
  if [[ -z "$vars_shell_format" ]]; then
    # We have to specify some vars in SHELL_FORMAT otherwise envsubst will
    # replace all environment variables in the target file, which is not what we
    # want.
    vars_shell_format=\\\$_NO_VARS_TO_REPLACE_
  fi

  echo "vars_shell_format = $vars_shell_format"
  local setup_slave_shell=${build_dir_name}/startup-scripts/setup-slaves.sh
  /bin/bash -c "$vars envsubst $vars_shell_format < ${setup_slave_shell}.template > ${setup_slave_shell}"
  rm ${setup_slave_shell}.template
}

function buildDockerImage() {
  local build_dir_name=${BUILD_DIR}/$1
  local local_image=$2
  local remote_image=$3
  if groups $USER | grep &>/dev/null '\bdocker\b'; then
    docker build -t $local_image $build_dir_name
    docker tag -f $local_image $remote_image
  else
    sudo docker build -t $local_image $build_dir_name
    sudo docker tag -f $local_image $remote_image
  fi
}

function pushDockerImage() {
  local remote_image=$1
  gcloud docker --authorize-only
  if groups $USER | grep &>/dev/null '\bdocker\b'; then
    docker push $remote_image
  else
    sudo docker push $remote_image
  fi
}

parseArguments $@

echo
echo "=========================================================="
echo Building $BUILD_TYPE base image now
echo "=========================================================="
case $BUILD_TYPE in
  testing)
    LOCAL_IMG=google/jenkins-base:testing
    REMOTE_IMG=gcr.io/developer_tools_bundle/jenkins-base:testing
    ENV_VARS=""
    ;;
  stable)
    LOCAL_IMG=google/jenkins-base:latest
    REMOTE_IMG=gcr.io/developer_tools_bundle/jenkins-base:latest
    ENV_VARS=""
    ;;
  local_version)
    LOCAL_IMG=google/jenkins-base:local_version
    REMOTE_IMG=gcr.io/${TARGET_PROJECT}/jenkins-base:local_version
    ENV_VARS=""
    ;;
esac
echo "Creating Dockerfile from template ..."
createDockerfileFromTemplate base base_$BUILD_TYPE $ENV_VARS
echo "Building Docker images now ..."
buildDockerImage base_$BUILD_TYPE $LOCAL_IMG $REMOTE_IMG
if [[ $PUSH_IMG == true ]]; then
  echo "Pushing $REMOTE_IMG now ..."
  pushDockerImage $REMOTE_IMG
fi

echo
echo "=========================================================="
echo Build $BUILD_TYPE slave images now
echo "=========================================================="
# Need to build slave images before master images, because master images
# contains script that need to know what slaves are available.
SDC=""
for slave_dir in `find slave_images -maxdepth 1 -type d -name "jenkins-slave-*"`;
do
  SLAVE_NAME=`basename $slave_dir`
  if [[ -z $SDC ]]; then
   SDC=$SLAVE_NAME
  else
    SDC=${SDC},${SLAVE_NAME}
  fi
  case $BUILD_TYPE in
    testing)
      LOCAL_IMG=google/${SLAVE_NAME}:testing
      REMOTE_IMG=gcr.io/developer_tools_bundle/${SLAVE_NAME}:testing
      ENV_VARS="_BASE_IMG_=gcr.io/developer_tools_bundle/jenkins-base:testing"
      ;;
    stable)
      LOCAL_IMG=google/${SLAVE_NAME}:latest
      REMOTE_IMG=gcr.io/developer_tools_bundle/${SLAVE_NAME}:latest
      ENV_VARS="_BASE_IMG_=gcr.io/developer_tools_bundle/jenkins-base:latest"
      ;;
    local_version)
      LOCAL_IMG=google/${SLAVE_NAME}:local_version
      REMOTE_IMG=gcr.io/${TARGET_PROJECT}/${SLAVE_NAME}:local_version
      ENV_VARS="_BASE_IMG_=gcr.io/${TARGET_PROJECT}/jenkins-base:local_version"
      ;;
  esac
  echo "Creating $SLAVE_NAME Dockerfile from template ..."
  createDockerfileFromTemplate slave_images/${SLAVE_NAME} ${SLAVE_NAME}_$BUILD_TYPE $ENV_VARS
  echo "Building Docker images now ..."
  buildDockerImage base_$BUILD_TYPE $LOCAL_IMG $REMOTE_IMG
  if [[ $PUSH_IMG == true ]]; then
    echo "Pushing $REMOTE_IMG now ..."
    pushDockerImage $REMOTE_IMG
  fi
done
SLAVE_IMG_PREFIX=${REMOTE_IMG%/*}
SLAVE_IMG_LABEL=":"${REMOTE_IMG##*:}

echo
echo "=========================================================="
echo Build $BUILD_TYPE master images now
echo "=========================================================="
case $BUILD_TYPE in
  testing)
    LOCAL_IMG=google/jenkins-appengine:testing
    REMOTE_IMG=gcr.io/developer_tools_bundle/jenkins:testing
    ENV_VARS="_BASE_IMG_=gcr.io/developer_tools_bundle/jenkins-base:testing"
    ;;
  stable)
    LOCAL_IMG=google/jenkins-appengine:latest
    REMOTE_IMG=gcr.io/developer_tools_bundle/jenkins:latest
    ENV_VARS="_BASE_IMG_=gcr.io/developer_tools_bundle/jenkins-base:latest"
    ;;
  local_version)
    LOCAL_IMG=google/jenkins-appengine:local_version
    REMOTE_IMG=gcr.io/${TARGET_PROJECT}/jenkins:local_version
    ENV_VARS="_BASE_IMG_=gcr.io/${TARGET_PROJECT}/jenkins-base:local_version"
    ;;
esac
echo "Creating master Dockerfile from template ..."
createDockerfileFromTemplate master_images master_$BUILD_TYPE $ENV_VARS
ENV_VARS="_SDC_=$SDC _SLAVE_IMG_PREFIX_=${SLAVE_IMG_PREFIX} _SLAVE_IMG_LABEL_=${SLAVE_IMG_LABEL}"
createSlaveSetupScriptFromTemplate master_$BUILD_TYPE $ENV_VARS
echo "Building Docker images now ..."
buildDockerImage master_$BUILD_TYPE $LOCAL_IMG $REMOTE_IMG
if [[ $PUSH_IMG == true ]]; then
  echo "Pushing $REMOTE_IMG now ..."
  pushDockerImage $REMOTE_IMG
fi
