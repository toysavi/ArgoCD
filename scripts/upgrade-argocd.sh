#!/bin/bash
set -e

TARGET_VERSION=$1
source ./config/env.conf

if [[ -z "$TARGET_VERSION" ]]; then
  echo "[ERROR] Target version not specified!"
  exit 1
fi

echo "[INFO] Updating ArgoCD manifests to version ${TARGET_VERSION}..."

# Example: patch deployment image
kubectl -n ${NAMESPACE} set image deployment/argocd-server \
  argocd-server=argoproj/argocd:${TARGET_VERSION}

kubectl -n ${NAMESPACE} set image deployment/argocd-repo-server \
  argocd-repo-server=argoproj/argocd:${TARGET_VERSION}

kubectl -n ${NAMESPACE} set image deployment/argocd-application-controller \
  argocd-application-controller=argoproj/argocd:${TARGET_VERSION}

kubectl -n ${NAMESPACE} rollout status deployment/argocd-server
kubectl -n ${NAMESPACE} rollout status deployment/argocd-repo-server
kubectl -n ${NAMESPACE} rollout status deployment/argocd-application-controller

echo "[SUCCESS] ArgoCD upgraded to ${TARGET_VERSION}"