#!/usr/bin/env bash
# =============================================================================
# generate.sh — Scaffold App-of-Apps GitOps repo + push + ArgoCD sync
#
# What this does:
#   1. Creates a local GitOps repo with proper folder structure
#   2. Generates all Helm-based Application manifests (ArgoCD, Traefik, sample app)
#   3. Pushes to your Git remote
#   4. Syncs ArgoCD via argocd CLI (installs CLI if missing)
#
# Run AFTER install.sh has completed.
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

# =============================================================================
# ██  EDIT THESE BEFORE RUNNING  ██
# =============================================================================
GITOPS_REPO_URL="https://github.com/toysavi/ArgoCD.git"  # ← Git remote URL
GITOPS_REPO_BRANCH="main"
GITOPS_LOCAL_DIR="${HOME}/gitops-repo"                          # local clone path

ARGOCD_DOMAIN="argocd.khryma.com"
ARGOCD_NAMESPACE="argocd"
ARGOCD_ADMIN_PASS="Pa55w.rd"   # leave blank to read from k8s secret automatically

GIT_USER_NAME="Khryma GitOps"
GIT_USER_EMAIL="gitops@khryma.com"
# =============================================================================

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# ── Validate config ───────────────────────────────────────────────────────────
[[ "$GITOPS_REPO_URL" == *"YOUR_ORG"* ]] && \
  die "Set GITOPS_REPO_URL at the top of this script before running"

command -v git &>/dev/null || die "git is required: yum install git  OR  apt install git"
command -v kubectl &>/dev/null || die "kubectl not found — run install.sh first"

# ── Install argocd CLI if missing ─────────────────────────────────────────────
install_argocd_cli() {
  info "Installing argocd CLI..."
  local ARCH OS VER
  ARCH=$(uname -m); OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
  [[ "$ARCH" == "aarch64" ]] && ARCH="arm64"

  VER=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\(.*\)".*/\1/')
  VER="${VER:-v2.13.3}"

  curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${VER}/argocd-${OS}-${ARCH}" \
    -o /usr/local/bin/argocd
  chmod +x /usr/local/bin/argocd
  log "argocd CLI installed: $(argocd version --client --short 2>/dev/null || echo $VER)"
}

if ! command -v argocd &>/dev/null; then
  install_argocd_cli
else
  log "argocd CLI already present"
fi

# ── Resolve ArgoCD admin password ─────────────────────────────────────────────
if [[ -z "$ARGOCD_ADMIN_PASS" ]]; then
  ARGOCD_ADMIN_PASS=$(kubectl get secret argocd-initial-admin-secret \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -z "$ARGOCD_ADMIN_PASS" ]] && die \
    "Could not read ArgoCD admin password. Set ARGOCD_ADMIN_PASS manually at the top of this script."
  log "ArgoCD admin password resolved from cluster secret"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Scaffold GitOps repo locally
# ═════════════════════════════════════════════════════════════════════════════
banner "Phase 1 — Scaffold GitOps Repo"

# Clone or init
if [[ -d "${GITOPS_LOCAL_DIR}/.git" ]]; then
  warn "Repo already exists at ${GITOPS_LOCAL_DIR} — pulling latest"
  git -C "$GITOPS_LOCAL_DIR" pull --rebase origin "$GITOPS_REPO_BRANCH" 2>/dev/null || true
else
  info "Cloning ${GITOPS_REPO_URL} → ${GITOPS_LOCAL_DIR}..."
  if ! git clone "$GITOPS_REPO_URL" "$GITOPS_LOCAL_DIR" 2>/dev/null; then
    warn "Clone failed (empty remote?) — initialising new repo"
    mkdir -p "$GITOPS_LOCAL_DIR"
    git -C "$GITOPS_LOCAL_DIR" init
    git -C "$GITOPS_LOCAL_DIR" remote add origin "$GITOPS_REPO_URL" 2>/dev/null || true
    git -C "$GITOPS_LOCAL_DIR" checkout -b "$GITOPS_REPO_BRANCH" 2>/dev/null || true
  fi
fi

git -C "$GITOPS_LOCAL_DIR" config user.name  "$GIT_USER_NAME"
git -C "$GITOPS_LOCAL_DIR" config user.email "$GIT_USER_EMAIL"

log "Git repo ready at ${GITOPS_LOCAL_DIR}"

# ── Directory structure ────────────────────────────────────────────────────────
# gitops-repo/
# ├── apps/                   ← root app-of-apps watches this dir
# │   ├── argocd-app.yaml     ← ArgoCD self-manages via Helm
# │   ├── traefik-app.yaml    ← Traefik managed by ArgoCD
# │   └── sample-app.yaml     ← example workload
# ├── argocd/
# │   └── values.yaml         ← ArgoCD Helm values
# ├── traefik/
# │   └── values.yaml         ← Traefik Helm values
# └── sample-app/
#     ├── deployment.yaml
#     ├── service.yaml
#     └── ingress.yaml

mkdir -p "${GITOPS_LOCAL_DIR}"/{apps,argocd,traefik,sample-app}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Generate manifests
# ═════════════════════════════════════════════════════════════════════════════
banner "Phase 2 — Generate Application Manifests"

# ── apps/argocd-app.yaml ──────────────────────────────────────────────────────
info "Writing apps/argocd-app.yaml..."
cat > "${GITOPS_LOCAL_DIR}/apps/argocd-app.yaml" <<EOF
# ArgoCD self-manages its own Helm release via GitOps
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "1"          # deploy early
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: "7.7.11"
    helm:
      valueFiles:
      - \$values/argocd/values.yaml             # pulls from same Git repo
  sources:
  - repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: "7.7.11"
    helm:
      valueFiles:
      - \$values/argocd/values.yaml
  - repoURL: ${GITOPS_REPO_URL}
    targetRevision: ${GITOPS_REPO_BRANCH}
    ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
EOF
log "apps/argocd-app.yaml written"

# ── apps/traefik-app.yaml ─────────────────────────────────────────────────────
info "Writing apps/traefik-app.yaml..."
cat > "${GITOPS_LOCAL_DIR}/apps/traefik-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "0"          # Traefik first (infra)
spec:
  project: default
  sources:
  - repoURL: https://helm.traefik.io/traefik
    chart: traefik
    targetRevision: "33.2.1"
    helm:
      valueFiles:
      - \$values/traefik/values.yaml
  - repoURL: ${GITOPS_REPO_URL}
    targetRevision: ${GITOPS_REPO_BRANCH}
    ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
log "apps/traefik-app.yaml written"

# ── apps/sample-app.yaml ──────────────────────────────────────────────────────
info "Writing apps/sample-app.yaml..."
cat > "${GITOPS_LOCAL_DIR}/apps/sample-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: ${GITOPS_REPO_BRANCH}
    path: sample-app
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
log "apps/sample-app.yaml written"

# ── argocd/values.yaml ────────────────────────────────────────────────────────
info "Writing argocd/values.yaml..."
cat > "${GITOPS_LOCAL_DIR}/argocd/values.yaml" <<EOF
# ArgoCD Helm values — managed via GitOps
# Bump chart version in apps/argocd-app.yaml for upgrades (rolling update via GUI)

configs:
  params:
    server.insecure: true        # TLS terminated at Traefik

server:
  service:
    type: ClusterIP

  ingress:
    enabled: false               # We manage the Ingress separately

# Resource limits — tune to your node size
controller:
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 500m
      memory: 1Gi

repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 300m
      memory: 512Mi
EOF
log "argocd/values.yaml written"

# ── traefik/values.yaml ───────────────────────────────────────────────────────
info "Writing traefik/values.yaml..."
cat > "${GITOPS_LOCAL_DIR}/traefik/values.yaml" <<EOF
# Traefik Helm values — managed via GitOps

service:
  type: LoadBalancer              # MetalLB assigns 10.0.200.114

ports:
  web:
    redirectTo:
      port: websecure             # http → https
  websecure:
    tls:
      enabled: true

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 300m
    memory: 256Mi
EOF
log "traefik/values.yaml written"

# ── sample-app/ — minimal nginx workload ──────────────────────────────────────
info "Writing sample-app/ manifests..."

cat > "${GITOPS_LOCAL_DIR}/sample-app/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  namespace: sample-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sample-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0           # zero-downtime rolling update
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
      - name: sample-app
        image: nginx:1.27-alpine  # bump tag here → commit → ArgoCD rolling update
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
EOF

cat > "${GITOPS_LOCAL_DIR}/sample-app/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: sample-app
  namespace: sample-app
spec:
  selector:
    app: sample-app
  ports:
  - port: 80
    targetPort: 80
EOF

cat > "${GITOPS_LOCAL_DIR}/sample-app/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sample-app
  namespace: sample-app
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - sample.khryma.com
    secretName: khryma-tls-sample   # copy khryma-tls secret to sample-app ns if needed
  rules:
  - host: sample.khryma.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: sample-app
            port:
              number: 80
EOF

log "sample-app/ manifests written"

# ── README ────────────────────────────────────────────────────────────────────
cat > "${GITOPS_LOCAL_DIR}/README.md" <<'EOF'
# Khryma GitOps Repo

## Structure

```
apps/               ← Root app-of-apps (ArgoCD watches this)
  argocd-app.yaml   ← ArgoCD self-manages its own Helm release
  traefik-app.yaml  ← Traefik ingress controller
  sample-app.yaml   ← Example workload
argocd/
  values.yaml       ← ArgoCD Helm values
traefik/
  values.yaml       ← Traefik Helm values
sample-app/         ← Raw manifests for sample nginx workload
  deployment.yaml
  service.yaml
  ingress.yaml
```

## Rolling Update Workflow

1. Edit image tag in `sample-app/deployment.yaml` (or any manifest)
2. `git commit -am "chore: bump sample-app to vX.Y.Z" && git push`
3. ArgoCD detects the change and rolls pods automatically
   — OR — open ArgoCD UI → Application → **SYNC** for manual trigger

## ArgoCD Self-Upgrade

1. Edit `targetRevision` in `apps/argocd-app.yaml`
2. Commit + push
3. ArgoCD GUI → argocd app → **SYNC** → rolling update of ArgoCD itself
EOF

log "README.md written"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Commit + Push to Git
# ═════════════════════════════════════════════════════════════════════════════
banner "Phase 3 — Commit & Push to Git"

cd "$GITOPS_LOCAL_DIR"

git add -A

if git diff --cached --quiet; then
  warn "Nothing new to commit — repo is already up to date"
else
  git commit -m "feat: scaffold app-of-apps structure [generate.sh]"
  info "Pushing to ${GITOPS_REPO_URL} (branch: ${GITOPS_REPO_BRANCH})..."
  git push -u origin "$GITOPS_REPO_BRANCH"
  log "Pushed to remote"
fi

cd - >/dev/null

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4 — ArgoCD: patch root-app repo URL + sync everything
# ═════════════════════════════════════════════════════════════════════════════
banner "Phase 4 — ArgoCD Sync"

info "Logging into ArgoCD at https://${ARGOCD_DOMAIN}..."
argocd login "$ARGOCD_DOMAIN" \
  --username admin \
  --password "$ARGOCD_ADMIN_PASS" \
  --insecure \
  --grpc-web

log "ArgoCD login successful"

# Patch root-app to point at the correct Git repo URL (in case install.sh used placeholder)
info "Patching root-app repoURL → ${GITOPS_REPO_URL}..."
kubectl patch application root-app -n "$ARGOCD_NAMESPACE" \
  --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/source/repoURL\",\"value\":\"${GITOPS_REPO_URL}\"}]" \
  2>/dev/null || warn "root-app patch skipped (may already be correct)"

# Sync root-app — this triggers all child apps
info "Syncing root-app (app-of-apps)..."
argocd app sync root-app \
  --insecure \
  --grpc-web \
  --timeout 120 || warn "root-app sync returned non-zero (may be converging)"

# Wait for child apps to appear then sync them
sleep 10

for APP in argocd traefik sample-app; do
  if argocd app get "$APP" --insecure --grpc-web &>/dev/null; then
    info "Syncing ${APP}..."
    argocd app sync "$APP" \
      --insecure \
      --grpc-web \
      --timeout 120 || warn "${APP} sync returned non-zero — check ArgoCD UI"
    log "${APP} synced"
  else
    warn "${APP} not yet registered — root-app may still be propagating"
  fi
done

# ── Final status ──────────────────────────────────────────────────────────────
banner "Status"

argocd app list --insecure --grpc-web 2>/dev/null || kubectl get applications -n "$ARGOCD_NAMESPACE"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}ArgoCD UI     :${NC} https://${ARGOCD_DOMAIN}"
echo -e "${BOLD}GitOps repo   :${NC} ${GITOPS_REPO_URL}"
echo -e "${BOLD}Local clone   :${NC} ${GITOPS_LOCAL_DIR}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}▸ Rolling update any app:${NC}"
echo -e "  1. Edit image tag or values in ${GITOPS_LOCAL_DIR}/"
echo -e "  2. git commit -am 'chore: bump X' && git push"
echo -e "  3. ArgoCD UI → app → SYNC  (or auto-syncs within 3 min)"
echo ""
echo -e "${YELLOW}▸ Upgrade ArgoCD itself (GUI rolling update):${NC}"
echo -e "  1. Edit targetRevision in apps/argocd-app.yaml"
echo -e "  2. git commit && git push"
echo -e "  3. ArgoCD UI → argocd app → SYNC"
echo ""
log "Done! All apps pushed and synced 🚀"