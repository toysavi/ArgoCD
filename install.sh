#!/bin/bash
# k3s-check-install.sh
# Script to check and install K3s if not present, then install Helm and ArgoCD

LOGFILE="/var/log/k3s-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== K3s + Helm + ArgoCD Installation Script ==="
echo "Timestamp: $(date)"

## Check and install K3s
if command -v k3s >/dev/null 2>&1; then
    echo "K3s is already installed."
    echo "Version: $(k3s --version)"
else
    echo "K3s not found. Installing..."
    curl -sfL https://get.k3s.io | sh -
    
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

echo "Checking cluster status..."
kubectl get nodes
kubectl get pods -A
echo "K3s installation and verification complete."

## Check and install Helm
if ! command -v helm >/dev/null 2>&1; then
    echo "Helm not found. Installing..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "Helm is already installed."
    echo "Version: $(helm version)"
fi

## Install ArgoCD via Helm
echo "Installing ArgoCD via Helm..."

# Create namespace if not exists
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Add ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Pin chart version for upgrade control
ARGOCD_CHART_VERSION="7.3.6"

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version $ARGOCD_CHART_VERSION \
  --set server.service.type=ClusterIP \
  --set server.ingress.enabled=true \
  --set server.ingress.ingressClassName=traefik \
  --set server.ingress.hosts[0]=argocd.example.com \
  --set server.ingress.tls[0].hosts[0]=argocd.example.com \
  --set server.ingress.tls[0].secretName=argocd-tls \
  --set dex.enabled=true \
  --set redis.enabled=true

echo "Waiting for ArgoCD pods to be ready..."
kubectl rollout status deployment argocd-server -n argocd
kubectl get pods -n argocd

echo "ArgoCD installation complete."
echo "Access via https://argocd.example.com"
