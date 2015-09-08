#!/bin/bash
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
# Prepares a per-user environment of the developer shell container,
# and starts sshd to accept incoming user connections capable of
# authenticating using the specified SSH public keys.
#

set -o errexit
set -o nounset
set -o pipefail

# The SSH daemon will run this command to get a list of keys.
AUTHORIZED_KEYS_COMMAND=/google/devshell/authorized_keys.sh

if [[ -z "${DEVSHELL_USER:-}" ]]; then
  echo DEVSHELL_USER was not specified, not launching sshd.
  exit 0
fi

if [[ -z "${DEVSHELL_SSH_PORT:-}" ]]; then
  DEVSHELL_SSH_PORT=22
fi

if [[ -z "${DEVSHELL_SSH_ARGS:-}" ]]; then
  DEVSHELL_SSH_ARGS=
fi

echo "DEVSHELL_SSH_PORT: ${DEVSHELL_SSH_PORT}"
echo "DEVSHELL_SSH_ARGS: ${DEVSHELL_SSH_ARGS}"

DEVSHELL_USER_HOME="/home/${DEVSHELL_USER}"
BASHRC_GOOGLE="bashrc.google"
BASHRC_GOOGLE_PATH="/google/devshell/bashrc.google"
BASHRC_PATH="${DEVSHELL_USER_HOME}/.bashrc"

# Include user into docker group so that Docker is usable and into adm group
# so that the user can read /var/log logs.
USER_GROUPS=docker,adm,sudo

useradd --shell /bin/bash \
  -u 1000 -G ${USER_GROUPS} --create-home "${DEVSHELL_USER}"

if ! grep -q "${BASHRC_GOOGLE_PATH}" "${BASHRC_PATH}"; then
  (
    echo
    echo "if [ -f \"${BASHRC_GOOGLE_PATH}\" ]; then"
    echo "  source \"${BASHRC_GOOGLE_PATH}\""
    echo "fi"
  ) >> "${BASHRC_PATH}"
fi

# Disables GCE credential lookup as there is no metadata server to communicate
# with in Devshell sessions.  Updating the configuration file directly rather
# than invoking gcloud since this is much faster.
logger -p local0.info "Updating gcloud installation scope config"
echo -ne '[core]\ncheck_gce_metadata = False\n' >>/google/google-cloud-sdk/properties

# Propagate container PATH environment to the user's.
echo "export PATH=$PATH" >/google/devshell/bashrc.google.d/env.sh

if [[ ! -f /etc/ssh/ssh_host_rsa_key || ! -f /etc/ssh/ssh_host_dsa_key  ]]; then
  # If SSH host keys are missing, generates a new set of keys.
  # Skips the key generation if the keys are present - e.g. if the VM host
  # keys have been mapped into the container.
  logger -p local0.info "Generating new set of host SSH keys"
  dpkg-reconfigure openssh-server
else
  logger -p local0.info "Host SSH keys exist, skipping the generation"
fi

# Finally, start ssdh in the background.
/usr/sbin/sshd ${DEVSHELL_SSH_ARGS} \
  -p "${DEVSHELL_SSH_PORT}" \
  -o AuthorizedKeysCommand="${AUTHORIZED_KEYS_COMMAND}" \
  -o AuthorizedKeysCommandUser=root
