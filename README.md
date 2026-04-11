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
