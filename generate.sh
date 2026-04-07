#!/usr/bin/env bash
set -e

BASE="argocd"
ZIP_NAME="argocd-gitops.zip"

echo "Creating structure..."

mkdir -p $BASE/{bootstrap,apps/argocd/values,apps/guestbook,apps/base,clusters/dev,clusters/staging,clusters/prod,overlays/dev,overlays/prod,projects}

########################################
# FILES
########################################

# README
cat <<EOF > $BASE/README.md
# ArgoCD GitOps Platform

See deployment steps:
1. ./bootstrap/install-argocd.sh
2. kubectl apply -f bootstrap/root-app.yaml
EOF

# INSTALL SCRIPT
cat <<EOF > $BASE/bootstrap/install-argocd.sh
#!/usr/bin/env bash
set -e

kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --version 5.51.6
EOF
chmod +x $BASE/bootstrap/install-argocd.sh

# ROOT APP
cat <<EOF > $BASE/bootstrap/root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_REPO/argocd.git
    targetRevision: HEAD
    path: clusters
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ARGOCD BASE VALUES
cat <<EOF > $BASE/apps/argocd/values.yaml
server:
  service:
    type: ClusterIP
dex:
  enabled: true
redis:
  enabled: true
EOF

# DEV VALUES
cat <<EOF > $BASE/apps/argocd/values/dev.yaml
server:
  config:
    url: https://argocd-dev.example.com
EOF

# PROD VALUES
cat <<EOF > $BASE/apps/argocd/values/prod.yaml
server:
  config:
    url: https://argocd.example.com
EOF

# ARGOCD APP
cat <<EOF > $BASE/apps/argocd/app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-self
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-cd
    targetRevision: 5.51.6
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# GUESTBOOK APP
cat <<EOF > $BASE/apps/guestbook/app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# BASE KUSTOMIZE
cat <<EOF > $BASE/apps/base/kustomization.yaml
resources:
- ../guestbook/app.yaml
EOF

# CLUSTERS
cat <<EOF > $BASE/clusters/dev/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-apps
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/YOUR_REPO/argocd.git
    path: apps
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

cp $BASE/clusters/dev/apps.yaml $BASE/clusters/staging/apps.yaml
cp $BASE/clusters/dev/apps.yaml $BASE/clusters/prod/apps.yaml

# PROJECT
cat <<EOF > $BASE/projects/dev-project.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dev
  namespace: argocd
spec:
  destinations:
  - namespace: "*"
    server: "*"
  sourceRepos:
  - "*"
EOF

########################################
# ZIP IT
########################################

echo "Creating ZIP..."
zip -r $ZIP_NAME $BASE

echo "✅ Done: $ZIP_NAME"