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

mkdir -p /var/log/app_engine/custom_logs
export JENKINS_HOME=/jenkins

function chown_cat() {
  cat > $1
  chown root:root $1
  chmod 777 $1
}

APP_BUCKET=$(curl -f http://metadata/computeMetadata/v1beta1/instance/attributes/gae_app_bucket || true)
MODULE=$(curl -f http://metadata/computeMetadata/v1beta1/instance/attributes/gae_backend_name -f || true)
VERSION=$(curl -f http://metadata/computeMetadata/v1beta1/instance/attributes/gae_backend_version || true)
PROJECT_NUM=$(curl -f http://metadata/computeMetadata/v1beta1/project/numeric-project-id || false)
METRICS_OPTIN=$(curl -f http://metadata/computeMetadata/v1beta1/project/attributes/google_report_usage || false)
ANALYTICS_ID=$(curl -f http://metadata/computeMetadata/v1beta1/project/attributes/google_report_analytics_id || false)
PROJECT_ID=$(curl -f http://metadata/computeMetadata/v1beta1/project/project-id || true)

if [[ -n "$PROJECT_NUM" ]]; then
  HASHED_PROJECT_NUM=$(echo -n "$PROJECT_NUM" | sha1sum | awk '{print $1}')
else
  HASHED_PROJECT_NUM=""
fi

if [[ -n "$CONFIG_BUCKET" ]]; then
  BUCKET=$CONFIG_BUCKET
else
  BUCKET=vm-containers.${APP_BUCKET#vm-config.}/jenkins-backup/$MODULE/$VERSION
fi

chown_cat $JENKINS_HOME/google-cloud-backup.xml <<BACKUP_XML
<?xml version='1.0' encoding='UTF-8'?>
<com.google.jenkins.plugins.persistentmaster.PersistentMasterPlugin plugin="google-cloud-backup@0.2">
  <enableBackup>true</enableBackup>
  <enableAutoRestore>true</enableAutoRestore>
  <restoreOverwritesData>false</restoreOverwritesData>
  <fullBackupIntervalHours>1</fullBackupIntervalHours>
  <incrementalBackupIntervalMinutes>3</incrementalBackupIntervalMinutes>
  <storageProvider class="com.google.jenkins.plugins.persistentmaster.storage.GcloudGcsStorageProvider">
    <bucket>$BUCKET</bucket>
  </storageProvider>
</com.google.jenkins.plugins.persistentmaster.PersistentMasterPlugin>
BACKUP_XML

chown_cat $JENKINS_HOME/google-analytics-usage-reporter.xml <<USAGE_REPORT_XML
<?xml version='1.0' encoding='UTF-8'?>
<com.google.jenkins.plugins.usage.GoogleUsageReportingPlugin plugin="google-analytics-usage-reporter@0.3">
  <enableReporting>$METRICS_OPTIN</enableReporting>
  <cloudProjectNumberHash>$HASHED_PROJECT_NUM</cloudProjectNumberHash>
  <analyticsId>$ANALYTICS_ID</analyticsId>
</com.google.jenkins.plugins.usage.GoogleUsageReportingPlugin>
USAGE_REPORT_XML

chown_cat $JENKINS_HOME/jenkins.model.JenkinsLocationConfiguration.xml << LOCATION_CONFIG_XML
<?xml version='1.0' encoding='UTF-8'?>
<jenkins.model.JenkinsLocationConfiguration>
  <adminAddress>address not configured yet &lt;nobody@nowhere&gt;</adminAddress>
  <jenkinsUrl>https://jenkins-dot-${PROJECT_ID}.appspot.com</jenkinsUrl>
</jenkins.model.JenkinsLocationConfiguration>
LOCATION_CONFIG_XML

java -jar jenkins.war --httpPort=5000 --logfile=/var/log/app_engine/custom_logs/jenkins.log
