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
# Dumps the list of public keys authorized to authenticate with Devshell
# containers for the current user. Used with sshd_config's AuthorizedKeysCommand
# option.
#

set -o errexit
set -o nounset
set -o pipefail

wget -q \
    --header 'Metadata-Flavor:Google' -O - \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/google-devshell-ssh-keys \
    | sed 's/^[^:]*://' # The metadata is in GCE format, lstrip the user name.
