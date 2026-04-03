#!/bin/bash
set -e

source ./configs/env.conf
source ./configs/versions.conf

read -p "Enter version [default: ${DEFAULT_VERSION}]: " VERSION
VERSION=${VERSION:-$DEFAULT_VERSION}

kubectl create namespace ${NAMESPACE}

kubectl apply -n ${NAMESPACE} \
  -f ${REPO_URL}/${VERSION}/manifests/install.yaml

kubectl rollout status deployment/argocd-server -n ${NAMESPACE}