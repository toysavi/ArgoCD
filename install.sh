#!/bin/bash
# k3s-check-install.sh
# Script to check and install K3s if not present

##  Install K3s

LOGFILE="/var/log/k3s-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== K3s Installation Script ==="
echo "Timestamp: $(date)"

# Check if k3s is already installed
if command -v k3s >/dev/null 2>&1; then
    echo "K3s is already installed."
    echo "Version: $(k3s --version)"
else
    echo "K3s not found. Installing..."
    curl -sfL https://get.k3s.io | sh -
    
    # Wait for service to start
    echo "Waiting for K3s service to start..."
    sleep 10
    
    if systemctl is-active --quiet k3s; then
        echo "K3s installed successfully."
        echo "Version: $(k3s --version)"
    else
        echo "ERROR: K3s installation failed or service not running."
        exit 1
    fi
fi

# Verify cluster status
echo "Checking cluster status..."
kubectl get nodes
kubectl get pods -A
echo "K3s installation and verification complete."

## Install ArgoCD

sudo ./bootstrap/install-argocd.sh