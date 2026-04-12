#!/usr/bin/env bash
# =============================================================================
# apply-rancher-argocd.sh
#
# Registers rancher-stable Helm repo in ArgoCD and applies the
# rancher + rancher-ingress Application manifests.
#
# Run on the k3s server. Assumes ArgoCD is already running.
# =============================================================================
set -euo pipefail

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

# ── Config ────────────────────────────────────────────────────────────────────
ARGOCD_DOMAIN="argocd.khryma.com"
ARGOCD_NAMESPACE="argocd"
ARGOCD_ADMIN_PASS="Pa55w.rd"              # blank = auto-read from cluster secret

GITOPS_REPO_URL="https://github.com/toysavi/ArgoCD.git"  # ← your repo
GITOPS_LOCAL="${HOME}/gitops-repo"

RANCHER_HOSTNAME="rancher.khryma.com"
RANCHER_HELM_VERSION="2.13.3"

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# ── Pre-flight ────────────────────────────────────────────────────────────────
banner "Pre-flight"

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash apply-rancher-argocd.sh"
[[ "$GITOPS_REPO_URL" == *"YOUR_ORG"* ]] && die "Set GITOPS_REPO_URL at the top"

command -v kubectl &>/dev/null || die "kubectl not found"

# Install argocd CLI if missing
if ! command -v argocd &>/dev/null; then
  info "Installing argocd CLI..."
  ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  VER=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  curl -fsSL \
    "https://github.com/argoproj/argo-cd/releases/download/${VER}/argocd-linux-${ARCH}" \
    -o /usr/local/bin/argocd
  chmod +x /usr/local/bin/argocd
  log "argocd CLI installed"
fi

log "Pre-flight OK"

# ── Step 1 : ArgoCD login ─────────────────────────────────────────────────────
banner "Step 1 — ArgoCD login"

if [[ -z "$ARGOCD_ADMIN_PASS" ]]; then
  ARGOCD_ADMIN_PASS=$(kubectl get secret argocd-initial-admin-secret \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -z "$ARGOCD_ADMIN_PASS" ]] && \
    die "Cannot read admin password. Set ARGOCD_ADMIN_PASS at top of script."
fi

argocd login "$ARGOCD_DOMAIN" \
  --username admin \
  --password "$ARGOCD_ADMIN_PASS" \
  --insecure \
  --grpc-web
log "Logged in"

# ── Step 2 : Register public Helm repos in ArgoCD ────────────────────────────
banner "Step 2 — Register public Helm repos"

add_helm_repo() {
  local URL="$1" NAME="$2"
  if argocd repo list --insecure --grpc-web 2>/dev/null | grep -q "$URL"; then
    warn "${NAME} already registered"
  else
    argocd repo add "$URL" \
      --type helm \
      --name "$NAME" \
      --insecure \
      --grpc-web
    log "${NAME} registered: ${URL}"
  fi
}

# rancher-stable — public, no auth needed
add_helm_repo "https://releases.rancher.com/server-charts/stable" "rancher-stable"

# jetstack — for cert-manager
add_helm_repo "https://charts.jetstack.io" "jetstack"

argocd repo list --insecure --grpc-web

# ── Step 3 : Write Application manifests into gitops-repo ─────────────────────
banner "Step 3 — Write Application manifests to gitops-repo"

[[ -d "${GITOPS_LOCAL}/.git" ]] || \
  die "GitOps repo not found at ${GITOPS_LOCAL}. Clone it first:\n  git clone ${GITOPS_REPO_URL} ${GITOPS_LOCAL}"

mkdir -p "${GITOPS_LOCAL}/apps"
mkdir -p "${GITOPS_LOCAL}/rancher-infra"

# apps/rancher-app.yaml — pulls chart from PUBLIC rancher-stable, inline values
cat > "${GITOPS_LOCAL}/apps/rancher-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://releases.rancher.com/server-charts/stable
    chart: rancher
    targetRevision: "${RANCHER_HELM_VERSION}"
    helm:
      releaseName: rancher
      values: |
        hostname: ${RANCHER_HOSTNAME}
        replicas: 1
        tls: external
        ingress:
          enabled: false
        bootstrapPassword: ""
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 2Gi
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-system
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    - Replace=true
EOF
log "apps/rancher-app.yaml written"

# apps/cert-manager-app.yaml — from public jetstack repo, inline values
cat > "${GITOPS_LOCAL}/apps/cert-manager-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: "v1.16.3"
    helm:
      releaseName: cert-manager
      values: |
        crds:
          enabled: false
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    - Replace=true
    automated:
      prune: true
      selfHeal: true
EOF
log "apps/cert-manager-app.yaml written"

# apps/rancher-ingress-app.yaml — raw manifests from gitops-repo/rancher-infra/
cat > "${GITOPS_LOCAL}/apps/rancher-ingress-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher-ingress
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: main
    path: rancher-infra
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-system
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    automated:
      prune: true
      selfHeal: true
EOF
log "apps/rancher-ingress-app.yaml written"

# rancher-infra/rancher-infra.yaml — ClusterIssuer + Certificate + Ingress
cat > "${GITOPS_LOCAL}/rancher-infra/rancher-infra.yaml" <<EOF
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: khryma-ca-issuer
spec:
  ca:
    secretName: khryma-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rancher-tls
  namespace: cattle-system
spec:
  secretName: rancher-tls
  issuerRef:
    name: khryma-ca-issuer
    kind: ClusterIssuer
  commonName: ${RANCHER_HOSTNAME}
  dnsNames:
  - ${RANCHER_HOSTNAME}
  duration: 87600h
  renewBefore: 720h
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher-ingress
  namespace: cattle-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - ${RANCHER_HOSTNAME}
    secretName: rancher-tls
  rules:
  - host: ${RANCHER_HOSTNAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: rancher
            port:
              number: 80
EOF
log "rancher-infra/rancher-infra.yaml written"

# ── Step 4 : Commit and push gitops-repo ─────────────────────────────────────
banner "Step 4 — Push to gitops-repo"

git -C "$GITOPS_LOCAL" add -A
if git -C "$GITOPS_LOCAL" diff --cached --quiet; then
  warn "Nothing new to commit in gitops-repo"
else
  git -C "$GITOPS_LOCAL" commit -m "feat: add rancher + cert-manager + ingress apps (public Helm repos)"
  git -C "$GITOPS_LOCAL" push
  log "gitops-repo pushed"
fi

# ── Step 5 : Sync root-app → propagates to all child apps ────────────────────
banner "Step 5 — Sync"

info "Syncing root-app..."
argocd app sync root-app \
  --insecure --grpc-web --timeout 120 || warn "root-app sync non-zero"

sleep 12

for APP in cert-manager rancher rancher-ingress; do
  if argocd app get "$APP" --insecure --grpc-web &>/dev/null; then
    info "Syncing ${APP}..."
    argocd app sync "$APP" \
      --insecure --grpc-web --timeout 180 || warn "${APP} sync non-zero — check GUI"
    log "${APP} synced"
  else
    warn "${APP} not yet visible — root-app propagating, retry in ~30s"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Complete"

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}ArgoCD UI    :${NC} https://${ARGOCD_DOMAIN}"
echo -e "${BOLD}Rancher UI   :${NC} https://${RANCHER_HOSTNAME}"
echo -e "${BOLD}Apps created :${NC} cert-manager, rancher, rancher-ingress"
echo -e "${BOLD}Chart source :${NC} https://releases.rancher.com/server-charts/stable"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}▸ Upgrade Rancher:${NC}"
echo -e "  Edit targetRevision in ${GITOPS_LOCAL}/apps/rancher-app.yaml"
echo -e "  git -C ${GITOPS_LOCAL} commit -am 'chore: upgrade rancher 2.13.4' && git push"
echo -e "  ArgoCD UI → rancher → SYNC"
echo ""
echo -e "${YELLOW}▸ Check apps:${NC}"
echo -e "  argocd app list --insecure --grpc-web"
echo -e "  kubectl get pods -n cattle-system"
echo ""
log "Done"