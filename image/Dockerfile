#
# Copyright 2015 Google Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
FROM gcr.io/developer_tools_bundle/jenkins-base

RUN mkdir -p /var/log/supervisor

# Configure NGINX
ADD nginx.conf /etc/nginx/nginx.conf

# Managed VM assume container listening at 8080
EXPOSE 8080

ENV DOCKER_HOST unix:///var/run/docker.sock

# Configure supervisord to start Jenkins, NGINX, and others (like wrapdocker)
ENTRYPOINT "/usr/bin/supervisord"
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Seed Jenkins default configuration.
ADD google-jenkins.war /jenkins.war
ADD jenkins /jenkins
ADD startup-scripts /startup-scripts
RUN chmod a+x /startup-scripts/*.sh

# startup-scripts/setup-slave.sh will mount a sub-directory of /container-tmp
# to /var/lib/docker.
# If we don't mount /container-tmp to host file system, it causes AUFS
# nested in outer AUFS directory, which is not supported and will
# cause slave container setup failure.
VOLUME /container-tmp

# Set the storage bucket to be used when backup/restore.
# If unset, the bucket vm-containers.APPID.appspot.com will be used.
#
# ENV CONFIG_BUCKET your-storage-bucket-here
