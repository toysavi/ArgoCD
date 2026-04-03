#!/bin/bash
set -e

echo "[INFO] Installing cert-manager..."

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

echo "[INFO] Waiting for cert-manager..."
kubectl wait --for=condition=Available deployment cert-manager -n cert-manager --timeout=180s

echo "[INFO] Applying Custom CA..."
kubectl apply -f manifests/cert-manager/ca-secret.yaml
kubectl apply -f manifests/cert-manager/cluster-issuer.yaml