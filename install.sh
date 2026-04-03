#!/bin/bash
set -e

# Load env
source ./config/env.conf

echo "[STEP 1] Check K3s..."
if ! command -v k3s >/dev/null 2>&1; then
    echo "[INFO] Installing K3s..."
    ./scripts/k3s-install.sh
else
    echo "[INFO] K3s already installed."
fi

echo "[STEP 2] Install or Upgrade ArgoCD..."

# Check if ArgoCD namespace exists
if ! kubectl get ns ${NAMESPACE} >/dev/null 2>&1; then
    echo "[INFO] ArgoCD namespace not found, installing fresh..."
    kubectl create ns ${NAMESPACE}
    ./scripts/install-argocd.sh
else
    echo "[INFO] ArgoCD namespace exists."

    # Get current ArgoCD version
    CURRENT_VERSION=$(kubectl -n ${NAMESPACE} get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $2}')
    
    if [[ -z "$CURRENT_VERSION" ]]; then
        echo "[WARN] Could not detect current ArgoCD version. Proceeding with installation..."
        ./scripts/install-argocd.sh
    else
        echo "[INFO] Current ArgoCD version: $CURRENT_VERSION"
        echo "Available version to upgrade (default: ${ARGOCD_VERSION}): "
        read -r TARGET_VERSION
        TARGET_VERSION=${TARGET_VERSION:-$ARGOCD_VERSION}

        if [[ "$TARGET_VERSION" == "$CURRENT_VERSION" ]]; then
            echo "[INFO] Already at version $CURRENT_VERSION. No upgrade needed."
        else
            echo "[INFO] Upgrading ArgoCD from $CURRENT_VERSION → $TARGET_VERSION"
            ./scripts/upgrade-argocd.sh "$TARGET_VERSION"
        fi
    fi
fi

echo "[STEP 3] Setup TLS..."
./scripts/tls.sh

echo "[STEP 4] Apply Ingress..."
./scripts/apply-ingress.sh

echo "[INFO] ArgoCD is ready at https://${HOST}"