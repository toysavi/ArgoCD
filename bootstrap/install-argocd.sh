#!/usr/bin/env bash
set -e

kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd   -n argocd   --version 5.51.6
