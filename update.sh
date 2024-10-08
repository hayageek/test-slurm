#!/usr/bin/env bash

# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

source ../../common.sh

SCRIPT_PATH="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_PATH}/../../../.." >/dev/null 2>&1 ; pwd -P)"
APP_PATH="${SCRIPT_PATH}/app"
TMP_DATA="/tmp/slurmweb_fingerprints"
GIT_REPO="${TMP_DATA}/repo"
FINGERPRINTS_PATH="${TMP_DATA}/fingerprints"
JSON_DATA="${FINGERPRINTS_PATH}/fingerprint.json"
BIN_DATA="${FINGERPRINTS_PATH}/fingerprint.binproto"
BINPROTO="${PROJECT_ROOT}/src/main/resources/fingerprinters/web/data/community/slurmweb.binproto"

mkdir -p "${FINGERPRINTS_PATH}"


buildSlurmWebImage(){
  local version="$1"
  pushd "${GIT_REPO}" >/dev/null
  cd docker/container
  docker build -t slurmweb:${version} -f Dockerfile .
  cd -
  popd >/dev/null
}

removeSlurmWebImage(){
  local version="$1"
  docker rmi -f slurmweb:${version}
}

startSlurmWeb(){
  local version="$1"
  pushd "${APP_PATH}" >/dev/null
  #SLURM_WEB_TAG="${version}" docker-compose up -d
  docker run  -d -v ${GIT_REPO}/conf:/etc/slurm-web \
              -v ${APP_PATH}/clusters.config.js:/etc/slurm-web/dashboard/clusters.config.js \
              -v ${APP_PATH}/config.json:/etc/slurm-web/dashboard/config.json \
              -p 8080:80 \
              slurmweb:${version}

  popd >/dev/null
}

stopContainer(){
  local name="$1"
  CONTAINER_ID=$(docker ps | grep "${name}" | cut -d " " -f1)
  if [ -n "$CONTAINER_ID" ]; then
    docker stop $CONTAINER_ID
  fi

}

stopSlurmWeb(){
  local version="$1"
  pushd "${APP_PATH}" >/dev/null
  SLURM_WEB_TAG="${version}" docker-compose down
  stopContainer "slurmweb:${version}"
  popd >/dev/null
}

waitForServer() {
  local url="http://localhost:8080/slurm/"
  local wait_time="${2:-5}"

  echo "Waiting for server at $url to be available..."

  while true; do
    http_response=$(curl --write-out "%{http_code}" --silent --output /dev/null "$url" || echo "failed")
    if [ "$http_response" -eq 200 ]; then
      echo "Server is up and running at $url!"
      break
    elif [ "$http_response" = "failed" ]; then
      echo "Curl command failed. Waiting for $wait_time seconds before retrying..."
    else
      echo "Server not yet available (HTTP status: $http_response). Waiting for $wait_time seconds..."
    fi
    sleep "$wait_time"
  done
}



# Convert existing data file to a human-readable JSON file
convertFingerprint "${BINPROTO}" "${JSON_DATA}"


# Read all versions to be fingerprinted
readarray -t ALL_VERSIONS < "${SCRIPT_PATH}/versions.txt"

# Clone Slurm-web repository if not already present
if [[ ! -d "${GIT_REPO}" ]]; then
  git clone https://github.com/rackslab/Slurm-web.git "${GIT_REPO}"
fi

# Update fingerprints for all listed versions
for app_version in "${ALL_VERSIONS[@]}"; do
  echo "Fingerprinting slurmweb UI version ${app_version} ..."

  # Checkout the repository to the correct tag
  checkOutRepo "${GIT_REPO}" "v${app_version}"

  # Build and run the container
  buildSlurmWebImage "${app_version}"

  # Start the cluser and slurmweb
  startSlurmWeb "${app_version}"

  echo "Waiting for slurmweb ${app_version} to be ready ..."
  sleep 10

  # Wait for the container to be fully up
  waitForServer

  echo "Application is up, updating fingerprint."

  # Capture the fingerprints
  updateFingerprint \
    "slurmweb" \
    "${app_version}" \
    "${FINGERPRINTS_PATH}" \
    "${GIT_REPO}" \
    "http://localhost:8080/slurm/"

  # Stop and remove the container
  stopSlurmWeb "${app_version}"

  removeSlurmWebImage "${app_version}"


done


# Convert the updated JSON data to binary proto format
convertFingerprint "${JSON_DATA}" "${BIN_DATA}"

echo "Fingerprint updated for slurmweb UI. Please commit the following file:"
echo "  ${BIN_DATA}"
echo "to"
echo "  ${BINPROTO}"
