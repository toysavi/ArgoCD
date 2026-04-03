# ArgoCD Deployment on K3s with TLS, LDAP & RBAC

## 1️⃣ Guideline

This repository provides a **production-ready deployment of ArgoCD on K3s**.  
It is designed for:

- **Secure HTTPS** access using custom TLS certificates  
- **LDAP authentication** integration  
- **Custom RBAC roles** for multiple teams (Admin, DevOps, Developer, ReadOnly, Infra)  
- **Automated installation and upgrade flow**  
- **GitOps-friendly** deployment of manifests and configs  

All configurations are centralized, and the workflow is automated via scripts.

---

## 2️⃣ Architecture

```text
          ┌─────────────┐
          │   Clients   │
          └─────┬───────┘
                │ HTTPS (TLS)
          ┌─────▼───────┐
          │  Traefik    │  <- Ingress
          └─────┬───────┘
                │
       ┌────────▼────────┐
       │  ArgoCD Server  │
       │  (Applications) │
       └───┬─────────┬───┘
           │         │
   ┌───────▼───┐ ┌───▼───────┐
   │Repo-Server│ │ App-Control│
   └───────────┘ └───────────┘
           │         │
           │         │
     ┌─────▼─────────▼─────┐
     │   Git Repositories  │
     │ (Manifests/Apps)    │
     └─────────────────────┘
```
LDAP Authentication → ArgoCD
RBAC Roles → Admin / DevOps / Developer / ReadOnly / Infra
TLS → config/ssl/tls.crt + tls.key
- Ingress (Traefik): Manages HTTPS access to ArgoCD
- ArgoCD Components: `server`, `repo-server`, `application-controller`
- LDAP: Maps user groups to ArgoCD RBAC roles
- TLS: Secure communication

## 3️⃣ Requirements
- K3s cluster installed (>= v1.28 recommended)
- `kubectl` CLI installed
- Access to LDAP server for authentication
- Public TLS certificate (`tls.crt`) and private key (`tls.key`)
- Internet access to download ArgoCD manifests
Optional:
- `envsubst` command for dynamic variable replacement
- Traefik ingress controller deployed

## 4️⃣ Variables Configuration (`config/env.conf`)
```
# Namespace
NAMESPACE="argocd"

# Host / FQDN
HOST="argocd.yourdomain.com"

# TLS
TLS_SECRET="argocd-tls"
SSL_CERT="./config/ssl/tls.crt"
SSL_KEY="./config/ssl/tls.key"

# ArgoCD version (default stable)
ARGOCD_VERSION="v2.11.3"

# LDAP
LDAP_HOST="ldap.yourdomain.com:636"
LDAP_BIND_DN="CN=svc-argocd,OU=Service Accounts,DC=yourdomain,DC=com"
LDAP_BIND_PW="changeme"
LDAP_BASE_DN="DC=yourdomain,DC=com"

# K3s token (optional)
K3S_TOKEN="mysecuretoken"
```
These variables are used throughout the scripts and manifests for dynamic configuration.

## 5️⃣ Install / Deploy
1. Make scripts executable
```
chmod +x scripts/*.sh
./scripts/install.sh
```
Installation Flow:

1. Check if `K3s` is installed → install if missinng(`k3s-install.sh`)
2. Check if ArgoCD namespace exists:
    - If missing → Install fresh (`install-argocd.sh`)
    - If exists → Prompt user for upgrade
3. Create TLS secret from `config/ssl/tls.crt` + `tls.key` (`tls.sh`)
4. Apply Ingress dynamically with host and secret (`apply-ingress.sh`)
5. Configure `LDAP` and `RBAC` via manifests

## 6️⃣ Upgrade ArgoCD
If ArgoCD is already installed, the script will:
1. Detect the current version of `ArgoCD`
2. Prompt the user for the target version (default from `ARGOCD_VERSION`)
3. Skip upgrade if already at target version
4. Perform *rolling update* on `argocd-server`, `repo-server`, and `application-controller`

*Manual Upgrade Command*
```
./scripts/upgrade-argocd.sh <target-version>
```

## 7️⃣ LDAP Integration & RBAC
| LDAP Group Name | ArgoCD Role |
| --------------- | ----------- |
| ldap-admins     | Admin       |
| ldap-devops     | DevOps      |
| ldap-developers | Developer   |
| ldap-readonly   | ReadOnly    |
| ldap-infra      | Infra       |

RBAC Configuration (`manifests/argocd/rbac.yaml`)

```
policy.csv: |
  g,ldap-admins,role:admin
  g,ldap-devops,role:devops
  g,ldap-developers,role:developer
  g,ldap-readonly,role:readonly
  g,ldap-infra,role:infra

  p,role:admin,applications,*,*
  p,role:devops,applications,create,*
  p,role:devops,applications,sync,*
  p,role:developer,applications,get,*
  p,role:developer,applications,sync,own
  p,role:readonly,applications,get,*
  p,role:infra,clusters,get,*
  p,role:infra,clusters,update,*
```