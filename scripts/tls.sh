#!/bin/bash
set -e

source ./config/env.conf

if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
  echo "[ERROR] TLS certificate or key not found!"
  exit 1
fi

echo "[INFO] Creating/updating TLS secret ${TLS_SECRET} in namespace ${NAMESPACE}"

kubectl -n ${NAMESPACE} delete secret ${TLS_SECRET} --ignore-not-found
kubectl -n ${NAMESPACE} create secret tls ${TLS_SECRET} \
  --cert="${SSL_CERT}" \
  --key="${SSL_KEY}"

echo "[SUCCESS] TLS secret created."