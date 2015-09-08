#!/bin/bash

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

SDC=${SDC:-java;go}

MASTER=$(hostname)
#Jenkins Master port
JMPORT=${JMPORT:-5000}
SLAVE_JAR=slave.jar
CLI_JAR=jenkins-cli.jar
RETRY=1200
SLEEP=5 #seconds
SUCCESS=""
echo "download Jenkins CLI jar ..."
for TRY in $(seq 1 $RETRY); do
  curl -O http://$MASTER:$JMPORT/jnlpJars/$CLI_JAR|| true
  # Verify that a jar file, not the "Please wait for Jenkins to be up" page
  # was downloaded. This should also cover the case that no file was downloaded.
  if zip -T $CLI_JAR; then
    SUCCESS=true
    break;
  fi
  echo "Jenkins may not be up and running yet, waiting..." 1>&2
  sleep $SLEEP
done

if [ -z "$SUCCESS" ]; then
  echo "[ERROR] Jenkins isn't up after $RETRY attempts." 1>&2
  exit -1
fi

echo "Removing old slaves ..."
java -jar jenkins-cli.jar -s "http://$MASTER:$JMPORT" \
  groovy = <<REMOVE_OLD_SDC
import jenkins.model.Jenkins

jenkins = Jenkins.instance

// first, find all the SDC nodes
sdcNodes = jenkins.nodes.findAll { node ->
  null != node.assignedLabels.find { label ->
    label.name =~ "^docker-slave-[^:/]+"
  }
}

// Then remove all of them
sdcNodes.each { sdcNode ->
  println "removing node " + sdcNode
  jenkins.removeNode(sdcNode)
}
REMOVE_OLD_SDC

for AN_SDC in ${SDC//;/ }
do
  SLAVE_NAME=jenkins-slave-$AN_SDC
  IMAGE_NAME="gcr.io/developer_tools_bundle/$SLAVE_NAME"
  echo "pull slave image $IMAGE_NAME ..."
  gcloud docker pull $IMAGE_NAME
  echo "Spin up slave container $SLAVE_NAME with label $SLAVE_NAME"
  java -jar jenkins-cli.jar -s "http://$MASTER:$JMPORT" \
    create-node $SLAVE_NAME <<CONFIG_XML_SLAVE
    <slave>
      <name>$SLAVE_NAME</name>
      <description></description>
      <remoteFS>/var/jenkins/</remoteFS>
      <numExecutors>1</numExecutors>
      <mode>NORMAL</mode>
      <retentionStrategy class="hudson.slaves.RetentionStrategy\$Always"/>
      <!-- Give this node the label slave (because it is one)
           and the more specific label of its SDC -->
      <launcher class="hudson.slaves.JNLPLauncher"/>
      <label>docker-slave-$SLAVE_NAME</label>
      <nodeProperties/>
    </slave>
CONFIG_XML_SLAVE

  java -jar jenkins-cli.jar -s "http://$MASTER:$JMPORT" online-node $SLAVE_NAME

  cat > slave-startup-$SLAVE_NAME.sh <<EOF
# Child container doesn't know its parent container's hostname, but it does
# know its IP.
export PARENT_IP=\$(/sbin/ip route | awk '/default/ {print \$3}')
curl -O http://\$PARENT_IP:$JMPORT/jnlpJars/$SLAVE_JAR

# Download the slave-agent.jnlp file. At this point Jenkins is already up,
# therefore we won't see the "Please wait for Jenkins..." page any more.
export JNLP_FILE=slave-agent.jnlp
curl  --retry $RETRY --retry-delay $SLEEP \
  -O http://\$PARENT_IP:$JMPORT/computer/$SLAVE_NAME/\$JNLP_FILE

# The slaves stay up until the host VM is torn down,
# so ensure things stay up.  This allows us to reconnect
# slaves if the master has a temporary issue or is told
# by the user to restart.
while true
do
  # Stagger the connections
  java -jar $SLAVE_JAR -jnlpUrl file:///\$JNLP_FILE
  sleep 10

done
EOF

  SLAVE_TMP_DIR=/container-tmp/$SLAVE_NAME
  mkdir -p $SLAVE_TMP_DIR
  chmod 777 $SLAVE_TMP_DIR

  echo "spin up SLAVE container $SLAVE_NAME ..."
  nohup docker run --rm -i --privileged --name="$SLAVE_NAME" \
    -v $SLAVE_TMP_DIR/docker:/var/lib/docker \
    -v $SLAVE_TMP_DIR/slave-home:/var/jenkins \
    $IMAGE_NAME /bin/bash < slave-startup-$SLAVE_NAME.sh &
done
