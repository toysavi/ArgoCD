#!/bin/bash
set -e

source ./config/env.conf

echo "[INFO] Deploying ArgoCD ingress..."
envsubst < ./manifests/argocd/ingress.yaml | kubectl apply -f -
echo "[SUCCESS] Ingress applied for ${HOST}"