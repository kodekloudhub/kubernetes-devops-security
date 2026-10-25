#!/usr/bin/env bash
set -euo pipefail

dockerImageName=$(awk '$1=="FROM" {print $2; exit}' Dockerfile)

if [[ -z "$dockerImageName" ]]; then
    echo "ERROR: Could not determine the image name from Dockerfile"
    exit 1
fi

echo "Scanning image: $dockerImageName"

TRIVY="aquasec/trivy:0.17.2"

# Report HIGH vulnerabilities without failing the build
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.cache/trivy:/root/.cache/" \
  "$TRIVY" image --exit-code 0 --severity HIGH "$dockerImageName"

# Fail the build if CRITICAL vulnerabilities are found
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.cache/trivy:/root/.cache/" \
  "$TRIVY" image --exit-code 1 --severity CRITICAL "$dockerImageName"