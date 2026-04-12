#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Wire ArgoCD to your GitHub gitops-repo and sync all apps
#
# Run ONCE after install.sh has completed.
# After this, everything is managed from GitHub — no more manual kubectl/helm.
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

# =============================================================================
# ██  EDIT THESE  ██
GITHUB_USER="YOUR_GITHUB_USERNAME"
GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxx"    # GitHub PAT with repo scope
GITOPS_REPO="https://github.com/${GITHUB_USER}/gitops-repo.git"
ARGOCD_DOMAIN="argocd.khryma.com"
ARGOCD_ADMIN_PASS=""                     # blank = auto-read from cluster secret
# =============================================================================

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

banner "Pre-flight"
[[ $EUID -eq 0 ]] || die "Run as root"
[[ "$GITHUB_USER" == "YOUR_GITHUB_USERNAME" ]] && die "Set GITHUB_USER"
[[ "$GITHUB_PAT"  == "ghp_xxx"* ]]             && die "Set GITHUB_PAT"
command -v kubectl &>/dev/null || die "kubectl not found"

# Install argocd CLI
if ! command -v argocd &>/dev/null; then
  info "Installing argocd CLI..."
  ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  VER=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  curl -fsSL \
    "https://github.com/argoproj/argo-cd/releases/download/${VER}/argocd-linux-${ARCH}" \
    -o /usr/local/bin/argocd
  chmod +x /usr/local/bin/argocd
fi
log "Pre-flight OK"

banner "ArgoCD login"
if [[ -z "$ARGOCD_ADMIN_PASS" ]]; then
  ARGOCD_ADMIN_PASS=$(kubectl get secret argocd-initial-admin-secret \
    -n argocd -o jsonpath="{.data.password}" | base64 -d)
fi
argocd login "$ARGOCD_DOMAIN" \
  --username admin --password "$ARGOCD_ADMIN_PASS" \
  --insecure --grpc-web
log "Logged in"

banner "Register GitHub gitops-repo"
argocd repo add "$GITOPS_REPO" \
  --username "$GITHUB_USER" \
  --password "$GITHUB_PAT" \
  --upsert --insecure --grpc-web
log "gitops-repo registered"

banner "Register public Helm repos (no auth)"
for ENTRY in \
  "https://releases.rancher.com/server-charts/stable|rancher-stable" \
  "https://charts.jetstack.io|jetstack" \
  "https://helm.traefik.io/traefik|traefik" \
  "https://argoproj.github.io/argo-helm|argo"; do
  URL="${ENTRY%%|*}"; NAME="${ENTRY##*|}"
  if argocd repo list --insecure --grpc-web | grep -q "$URL"; then
    warn "${NAME} already registered"
  else
    argocd repo add "$URL" --type helm --name "$NAME" --insecure --grpc-web
    log "${NAME} registered"
  fi
done

banner "Apply root-app (bootstraps all other apps)"
# Replace YOUR_ORG in the manifest before applying
TMPFILE=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/gitops-repo/main/apps/root-app.yaml" \
  -o "$TMPFILE" 2>/dev/null || \
  cp "${HOME}/gitops-repo/apps/root-app.yaml" "$TMPFILE"

kubectl apply -f "$TMPFILE"
rm -f "$TMPFILE"
log "root-app applied"

banner "Sync"
sleep 5
argocd app sync root-app --insecure --grpc-web --timeout 120 || warn "root-app sync non-zero"

sleep 15
for APP in argocd traefik cert-manager rancher rancher-ingress; do
  if argocd app get "$APP" --insecure --grpc-web &>/dev/null 2>&1; then
    info "Syncing ${APP}..."
    argocd app sync "$APP" --insecure --grpc-web --timeout 180 \
      || warn "${APP} non-zero — check GUI"
    log "${APP} synced"
  else
    warn "${APP} not yet visible — will sync after root-app propagates"
  fi
done

banner "Done"
argocd app list --insecure --grpc-web
echo ""
echo -e "${BOLD}ArgoCD :${NC} https://${ARGOCD_DOMAIN}"
echo -e "${BOLD}Rancher:${NC} https://rancher.khryma.com"
echo ""
log "All apps managed from GitHub. Edit files → commit → push → SYNC in GUI."
