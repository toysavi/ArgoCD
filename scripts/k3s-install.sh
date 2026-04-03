#!/bin/bash
set -e

source ./configs/k3s.conf

echo "================================="
echo " K3s Installation"
echo "================================="

# Check if k3s already installed
if command -v k3s &>/dev/null; then
    echo "[INFO] K3s already installed"
    k3s kubectl get nodes
    exit 0
fi

echo "[INFO] Installing K3s version: ${K3S_VERSION}"

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} \
  K3S_TOKEN=${K3S_TOKEN} \
  INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC}" \
  sh -

echo "[INFO] Waiting for node ready..."
sleep 10

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl get nodes

echo "[SUCCESS] K3s installed"