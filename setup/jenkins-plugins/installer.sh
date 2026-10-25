#!/bin/bash
set -eo pipefail

JENKINS_URL='http://localhost:8080'
JENKINS_USER='admin'
JENKINS_PASSWORD='redhat'

echo "Checking Jenkins authentication..."

# Get Jenkins crumb
JENKINS_CRUMB=$(curl -fsS \
  --cookie-jar /tmp/cookies \
  -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
  "${JENKINS_URL}/crumbIssuer/api/json" |
  jq -r '.crumb')

if [ -z "$JENKINS_CRUMB" ] || [ "$JENKINS_CRUMB" = "null" ]; then
    echo "ERROR: Could not obtain Jenkins crumb."
    exit 1
fi

echo "Jenkins authentication successful."
echo "Jenkins URL: ${JENKINS_URL}"
echo "Jenkins Crumb: ${JENKINS_CRUMB}"

# Generate Jenkins API token
JENKINS_TOKEN=$(curl -fsS -X POST \
  -H "Jenkins-Crumb:${JENKINS_CRUMB}" \
  --cookie /tmp/cookies \
  -u "${JENKINS_USER}:${JENKINS_PASSWORD}" \
  "${JENKINS_URL}/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken?newTokenName=demo-token66" |
  jq -r '.data.tokenValue')

if [ -z "$JENKINS_TOKEN" ] || [ "$JENKINS_TOKEN" = "null" ]; then
    echo "ERROR: Could not generate Jenkins API token."
    exit 1
fi

echo "Jenkins API token generated successfully."

while read -r plugin; do

   # Skip empty lines and comments
   [[ -z "$plugin" || "$plugin" =~ ^# ]] && continue

   echo "........Installing ${plugin} .."

   curl -fsS -X POST \
     --data "<jenkins><install plugin='${plugin}' /></jenkins>" \
     -H 'Content-Type: text/xml' \
     -H "Jenkins-Crumb:${JENKINS_CRUMB}" \
     "${JENKINS_URL}/pluginManager/installNecessaryPlugins" \
     --user "${JENKINS_USER}:${JENKINS_TOKEN}"

done < plugins.txt

echo
echo "======================================"
echo " Jenkins plugin installation triggered"
echo "======================================"
