#!/usr/bin/env bash
# =============================================================================
# install.sh — k3s + MetalLB + Traefik + ArgoCD on argocd.khryma.com
# MetalLB IP : 10.0.200.114
# ArgoCD URL : https://argocd.khryma.com  (self-signed CA)
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
info()   { echo -e "${CYAN}[→]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
die()    { echo -e "${RED}[✘]${NC} $*" >&2; exit 1; }
banner() {
  echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════${NC}\n"
}

# ── Config (edit if needed) ───────────────────────────────────────────────────
METALLB_VERSION="v0.14.8"
ARGOCD_HELM_VERSION="7.7.11"
TRAEFIK_HELM_VERSION="33.2.1"
METALLB_IP="10.0.200.114"
ARGOCD_DOMAIN="argocd.khryma.com"
ARGOCD_NAMESPACE="argocd"
TRAEFIK_NAMESPACE="traefik"
CERT_DIR="/etc/khryma/certs"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
GITOPS_REPO_URL="https://github.com/toysavi/ArgoCD"   # ← CHANGE THIS

# ── PATH bootstrap ────────────────────────────────────────────────────────────
# k3s and Helm both install to /usr/local/bin — ensure it's in PATH
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ── Helper: install Helm via direct binary download (no git needed) ───────────
install_helm() {
  info "Installing Helm via direct binary download..."

  local ARCH
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm"   ;;
    *)       die "Unsupported architecture: $ARCH" ;;
  esac

  local OS
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  # Fetch latest Helm version tag without git
  local HELM_VER
  HELM_VER=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  HELM_VER="${HELM_VER:-v3.20.2}"

  info "Downloading Helm ${HELM_VER} (${OS}/${ARCH})..."
  local TMP
  TMP=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-${HELM_VER}-${OS}-${ARCH}.tar.gz" \
    -o "${TMP}/helm.tar.gz"
  tar -xzf "${TMP}/helm.tar.gz" -C "${TMP}"
  install -m 0755 "${TMP}/${OS}-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${TMP}"
  log "Helm installed: $(helm version --short)"
}

# ── PHASE 0 : Pre-flight ──────────────────────────────────────────────────────
banner "Pre-flight checks"

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

command -v curl   &>/dev/null || die "curl is required but not installed"
command -v openssl &>/dev/null || die "openssl is required but not installed"

if ! command -v helm &>/dev/null; then
  install_helm
else
  log "Helm already present: $(helm version --short)"
fi

log "Pre-flight OK"

# ── PHASE 1 : k3s ─────────────────────────────────────────────────────────────
banner "Phase 1 — k3s Install"

if systemctl is-active --quiet k3s 2>/dev/null; then
  warn "k3s is already running — skipping install"
else
  info "Installing k3s (servicelb + traefik disabled)..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable servicelb --disable traefik" sh -
  log "k3s installed"
fi

# k3s provides kubectl via symlink at /usr/local/bin/kubectl — ensure it exists
if ! command -v kubectl &>/dev/null; then
  if [[ -f /usr/local/bin/k3s ]]; then
    ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
    log "kubectl symlinked from k3s binary"
  else
    die "kubectl not found and k3s binary missing — check k3s install"
  fi
fi

export KUBECONFIG="$KUBECONFIG_PATH"

info "Waiting for node to be Ready (up to 150s)..."
for i in $(seq 1 30); do
  kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready" && break
  echo -n "."
  sleep 5
done
echo ""
kubectl get nodes --no-headers | grep -q " Ready" || die "Node never became Ready"
log "Node is Ready"
kubectl get nodes

# ── PHASE 2 : MetalLB ─────────────────────────────────────────────────────────
banner "Phase 2 — MetalLB $METALLB_VERSION"

info "Applying MetalLB manifests..."
kubectl apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

info "Waiting for MetalLB controller (up to 120s)..."
kubectl wait -n metallb-system deploy/controller \
  --for=condition=Available --timeout=120s
log "MetalLB controller ready"

info "Configuring IP pool: ${METALLB_IP}/32"
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: khryma-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: khryma-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - khryma-pool
EOF
log "MetalLB pool configured"

# ── PHASE 3 : Self-signed CA + Wildcard TLS cert ───────────────────────────────
banner "Phase 3 — Self-Signed CA + TLS Cert"

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

if [[ -f ca.crt && -f khryma-tls.crt ]]; then
  warn "Certs already exist in $CERT_DIR — skipping generation"
else
  info "Generating CA key + cert (4096-bit RSA, 10yr)..."
  openssl genrsa -out ca.key 4096 2>/dev/null
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/CN=khryma-ca/O=Khryma" \
    -out ca.crt

  info "Generating wildcard TLS cert for *.khryma.com..."
  openssl genrsa -out khryma-tls.key 2048 2>/dev/null
  openssl req -new -key khryma-tls.key \
    -subj "/CN=*.khryma.com/O=Khryma" \
    -out khryma-tls.csr

  cat > ext.cnf <<EXTEOF
[SAN]
subjectAltName=DNS:*.khryma.com,DNS:khryma.com
EXTEOF

  openssl x509 -req -in khryma-tls.csr \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out khryma-tls.crt -days 3650 -sha256 \
    -extfile ext.cnf -extensions SAN 2>/dev/null

  log "Certificates generated in $CERT_DIR"
fi

# Create argocd namespace and TLS secret
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret tls khryma-tls \
  -n "$ARGOCD_NAMESPACE" \
  --cert="${CERT_DIR}/khryma-tls.crt" \
  --key="${CERT_DIR}/khryma-tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

log "TLS secret 'khryma-tls' ready in namespace $ARGOCD_NAMESPACE"
cd - >/dev/null

# ── PHASE 4 : Traefik ─────────────────────────────────────────────────────────
banner "Phase 4 — Traefik $TRAEFIK_HELM_VERSION"

helm repo add traefik https://helm.traefik.io/traefik --force-update 2>/dev/null || true
helm repo update

kubectl create namespace "$TRAEFIK_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install traefik traefik/traefik \
  -n "$TRAEFIK_NAMESPACE" \
  --version "$TRAEFIK_HELM_VERSION" \
  --set service.type=LoadBalancer \
  --set "ports.web.redirectTo.port=websecure" \
  --set "ports.websecure.tls.enabled=true" \
  --wait --timeout=120s

info "Waiting for Traefik to receive IP ${METALLB_IP} from MetalLB..."
ASSIGNED_IP=""
for i in $(seq 1 30); do
  ASSIGNED_IP=$(kubectl get svc traefik -n "$TRAEFIK_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ "$ASSIGNED_IP" == "$METALLB_IP" ]] && break
  echo -n "."
  sleep 5
done
echo ""

if [[ "$ASSIGNED_IP" == "$METALLB_IP" ]]; then
  log "Traefik got LoadBalancer IP: $ASSIGNED_IP"
else
  warn "Traefik IP is '${ASSIGNED_IP:-<pending>}' — expected $METALLB_IP. MetalLB may still be converging."
fi

# ── PHASE 5 : ArgoCD ──────────────────────────────────────────────────────────
banner "Phase 5 — ArgoCD $ARGOCD_HELM_VERSION"

helm repo add argo https://argoproj.github.io/argo-helm --force-update 2>/dev/null || true
helm repo update

helm upgrade --install argocd argo/argo-cd \
  -n "$ARGOCD_NAMESPACE" \
  --version "$ARGOCD_HELM_VERSION" \
  --set 'configs.params.server\.insecure=true' \
  --set server.service.type=ClusterIP \
  --wait --timeout=300s

log "ArgoCD deployed"

# ── PHASE 6 : ArgoCD Ingress ──────────────────────────────────────────────────
banner "Phase 6 — ArgoCD Ingress (https://${ARGOCD_DOMAIN})"

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: ${ARGOCD_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - ${ARGOCD_DOMAIN}
    secretName: khryma-tls
  rules:
  - host: ${ARGOCD_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF
log "Ingress created: https://${ARGOCD_DOMAIN}"

# ── PHASE 7 : App-of-Apps root application ────────────────────────────────────
banner "Phase 7 — App-of-Apps Root Application"

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
log "Root app-of-apps created"

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Installation Complete"

ADMIN_PASS=$(kubectl get secret argocd-initial-admin-secret \
  -n "$ARGOCD_NAMESPACE" \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null \
  || echo "<run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d>")

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}ArgoCD UI  :${NC} https://${ARGOCD_DOMAIN}"
echo -e "${BOLD}Username   :${NC} admin"
echo -e "${BOLD}Password   :${NC} ${ADMIN_PASS}"
echo -e "${BOLD}MetalLB IP :${NC} ${METALLB_IP}"
echo -e "${BOLD}CA cert    :${NC} ${CERT_DIR}/ca.crt  ← import into browser"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}▸ Add to /etc/hosts on client machines:${NC}"
echo -e "  echo '${METALLB_IP}  ${ARGOCD_DOMAIN}' >> /etc/hosts"
echo ""
echo -e "${YELLOW}▸ Trust CA on macOS:${NC}"
echo -e "  sudo security add-trusted-cert -d -r trustRoot \\"
echo -e "    -k /Library/Keychains/System.keychain ${CERT_DIR}/ca.crt"
echo ""
echo -e "${YELLOW}▸ Trust CA on Linux clients:${NC}"
echo -e "  sudo cp ${CERT_DIR}/ca.crt /usr/local/share/ca-certificates/khryma-ca.crt"
echo -e "  sudo update-ca-certificates"
echo ""
echo -e "${YELLOW}▸ GitOps next step:${NC}"
echo -e "  Edit GITOPS_REPO_URL at the top of this script and re-run,"
echo -e "  or patch the root-app Application in ArgoCD UI."
echo ""
log "Done! Happy GitOps 🚀"