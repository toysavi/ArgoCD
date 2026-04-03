#!/bin/bash
set -e

source ./configs/env.conf
source ./configs/versions.conf

CURRENT=$(kubectl -n ${NAMESPACE} get deploy argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}' | awk -F ':' '{print $2}')

echo "[INFO] Current version: $CURRENT"

read -p "Upgrade? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

read -p "Target version [default: ${DEFAULT_VERSION}]: " VERSION
VERSION=${VERSION:-$DEFAULT_VERSION}

kubectl apply -n ${NAMESPACE} \
  -f ${REPO_URL}/${VERSION}/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n ${NAMESPACE}