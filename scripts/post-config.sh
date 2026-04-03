#!/bin/bash
set -e

source ./configs/env.conf

echo "[INFO] Creating certificate..."
kubectl apply -f manifests/argocd/certificate.yaml

echo "[INFO] Creating ingress..."
kubectl apply -f manifests/argocd/ingress.yaml

echo "[INFO] Admin password:"
kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo