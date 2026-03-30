# AGENTS.md - Guidelines for AI Coding Agents

This document provides instructions for AI agents working on this Hetzner Kubernetes GitOps repository.

## Table of Contents

- [Project Overview](#project-overview)
- [Directory Structure](#directory-structure)
- [Commands](#commands)
  - [Prerequisites](#prerequisites)
  - [Validation](#validation-commands)
  - [Testing](#running-tests)
  - [Helm](#helm-commands)
  - [ArgoCD](#argocd-operations)
- [Code Style Guidelines](#code-style-guidelines)
  - [YAML Formatting](#yaml-formatting)
  - [Naming Conventions](#naming-conventions)
  - [Import/Reference Patterns](#importreference-patterns)
  - [ArgoCD Application Patterns](#argocd-application-patterns)
  - [Crossplane Patterns](#crossplane-patterns)
  - [Error Handling](#error-handling)
  - [Security Best Practices](#security-best-practices)
- [Git Commit Conventions](#git-commit-conventions)
- [Environment Setup](#environment-setup)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [External References](#external-references)

## Project Overview

This repository manages Kubernetes infrastructure using:

- **ArgoCD**: GitOps controller for application deployment
- **Crossplane**: Cloud resource provisioning (OpenBao/Vault, Keycloak, DigitalOcean)
- **Helm Charts**: Package management for Kubernetes applications
- **Kubernetes**: Container orchestration on Hetzner Cloud

## Directory Structure

```
.
├── argocd/                          # ArgoCD Application definitions
│   ├── argocd/                      # ArgoCD self-managed deployment
│   │   └── argocd.yaml
│   ├── cert-manager/                # SSL/TLS certificate management
│   │   ├── application.yaml
│   │   └── cluster-issuer.yaml
│   ├── configurations/              # Crossplane configurations
│   │   └── crossplane-init.yaml
│   ├── crossplane/                  # Crossplane deployment
│   │   └── crossplane.yaml
│   ├── digitalOcean/                # DigitalOcean cluster configs
│   │   └── clusters/production.yaml
│   ├── doks-cluster/                # DOKS cluster application
│   │   └── application.yaml
│   ├── external-secrets/            # External Secrets Operator
│   │   └── application.yaml
│   ├── keycloak.yaml                # Keycloak application
│   ├── kong.yaml                    # Kong API gateway
│   ├── kubernetes_ingress.yaml      # Kubernetes ingress controller
│   ├── openbao/                     # OpenBao (Vault) Helm chart values
│   │   ├── openbao.yaml
│   │   └── values.yaml
│   └── init.yaml                    # Root ArgoCD application
├── charts/                          # Custom Helm charts
│   ├── doks-cluster/                # DOKS cluster chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   └── doks-cluster-base/           # DOKS cluster base chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── crossplane/                      # Crossplane resources
│   ├── config/                      # Provider configurations and compositions
│   │   ├── bao/                     # OpenBao secrets engine configs
│   │   │   └── bao-hnatekmar-xyz/
│   │   │       ├── algovectra/      # Project-specific configs
│   │   │       ├── auth/            # Authentication methods
│   │   │       ├── clusters/        # Kubernetes cluster secrets
│   │   │       ├── devops/          # Devops project configs
│   │   │       ├── hnatekmarorg/    # hnatekmarorg project configs
│   │   │       └── sso/             # SSO service configuration
│   │   ├── eso/                     # External Secrets configurations
│   │   │   └── secretStore/         # Secret store definitions
│   │   ├── keycloak/                # Keycloak identity management
│   │   │   ├── identity-providers/  # OIDC identity providers
│   │   │   ├── clients/             # OIDC clients and scopes
│   │   │   ├── groups/              # Group definitions
│   │   │   └── roles/               # Role and realm mappings
│   │   └── providers/               # Provider configs (bao, digitalocean, sso)
│   ├── init/                        # Initial provider setup
│   │   ├── functions/               # Crossplane functions (kcl, auto-ready)
│   │   └── providers/               # Provider installations (digitalocean, helm, keycloak, kubernetes, vault)
│   └── secrets/                     # Secret definitions
├── docs/                            # Documentation
│   ├── crossplane/                  # Crossplane-specific docs
│   │   ├── external-secrets.md
│   │   ├── initialization.md
│   │   ├── keycloak.md
│   │   ├── openbao.md
│   │   ├── provider-configs.md
│   │   └── sso-integration.md
│   └── workflows/                   # Workflow documentation
│       ├── adding-project-sso.md
│       └── troubleshooting.md
├── openspec/                        # OpenSpec configuration
│   ├── changes/                     # OpenSpec change records
│   └── config.yaml
├── init.yaml                        # Root ArgoCD application (legacy)
└── pod.yaml                         # External Secrets test pod
```

## Commands

### Prerequisites

```bash
# Load environment variables
direnv allow

# Verify kubectl access
kubectl cluster-info

# Check Crossplane providers
kubectl get providers -A
```

### Validation Commands

```bash
# Validate YAML syntax
find . -name "*.yaml" -exec yamllint {} \;

# Dry-run Kubernetes manifests
kubectl apply --dry-run=client -f <file>.yaml

# Validate Crossplane compositions
kubectl explain <kind>
```

### Running Tests

This repository uses declarative YAML manifests rather than traditional tests. Validation is done through:

```bash
# Kubectl server-side dry-run
kubectl apply --dry-run=server -f <manifest>.yaml
```

### Helm Commands

```bash
# Template a Helm chart
helm template <release> <chart> -f values.yaml

# Lint Helm charts
helm lint <chart>

# Get chart values
helm show values <chart-url>
```

### ArgoCD Operations

This repository uses GitOps with automatic syncing - manual syncs are rarely needed. When necessary, use kubectl:

```bash
# List ArgoCD applications
kubectl get app -n argocd

# Get application details and status
kubectl get app <app-name> -n argocd -o yaml

# Check application health and sync status
kubectl describe app <app-name> -n argocd

# Force retry (if stuck in sync error)
kubectl patch app <app-name> -n argocd --type=merge -p '{"spec":{"syncPolicy":{"retry":{"limit":5}}}}'
```

## Code Style Guidelines

### YAML Formatting

1. **Indentation**: Use 2-space indentation consistently
2. **Ordering**: Follow Kubernetes resource structure:

   ```yaml
   apiVersion: <version>
   kind: <kind>
   metadata:
     name: <name>
     namespace: <namespace>
     annotations: # Optional
     labels: # Optional
   spec:
     # Resource-specific configuration
   ```

3. **Comments**: Add comments for non-obvious configurations

   ```yaml
   # Sync wave for ordered deployment
   argocd.argoproj.io/sync-wave: "1"
   ```

### Naming Conventions

1. **Resources**: Use kebab-case for names
   - ✅ `bao-hnatekmar-xyz`
   - ❌ `baoHnatekmarXyz`

2. **Namespaces**: Use descriptive, lowercase names
   - ✅ `crossplane-system`, `external-secrets`, `keycloak`
   - ❌ `CrossplaneSystem`, `External_Secrets`

3. **Labels/Selectors**: Follow Kubernetes conventions

   ```yaml
   app.kubernetes.io/name: <app-name>
   app.kubernetes.io/component: <component>
   app.kubernetes.io/part-of: <project>
   ```

### Import/Reference Patterns

1. **Helm Chart References**: Include full chart URL and version

   ```yaml
   source:
     repoURL: https://codecentric.github.io/helm-charts
     chart: keycloakx
     targetRevision: 7.1.5
   ```

2. **Provider Configurations**: Use descriptive names with environment/region

   ```yaml
   metadata:
     name: bao-hnatekmar-xyz  # <provider>-<domain>
   ```

3. **Secret References**: Always reference secrets by name and key

   ```yaml
   valueFrom:
     secretKeyRef:
       name: keycloak-admin-creds
       key: password
   ```

### ArgoCD Application Patterns

1. **Sync Policy**: Always include automated sync with selfHeal and prune

   ```yaml
   syncPolicy:
     automated:
       selfHeal: true
       prune: true
     syncOptions:
       - CreateNamespace=true
   ```

2. **Sync Waves**: Use for deployment ordering

   ```yaml
   annotations:
     argocd.argoproj.io/sync-wave: "1"  # Lower = deploy first
   ```

3. **Retry Configuration**: Add for critical services

   ```yaml
   retry:
     limit: 5
     backoff:
       duration: 5s
       factor: 2
       maxDuration: 3m
   ```

### Crossplane Patterns

For detailed Crossplane resource patterns and configurations, see:

- **[Keycloak Configuration](docs/crossplane/keycloak.md)** - Groups, roles, clients, and mappings
  - **Required**: All OIDC clients for OpenBao must include `email` and `microprofile-jwt` default scopes
  - See [Client Default Scopes Configuration](docs/crossplane/keycloak.md#client-default-scopes-configuration) for details
  - **Client Pattern**: Each Keycloak client consists of three resources:
    - `Client` - Main client definition (sync-wave: "2")
    - `ClientDefaultScopes` - Required scopes automatically included in tokens (sync-wave: "5")
    - `ClientOptionalScopes` - Optional scopes that can be requested (sync-wave: "5")
  - See [Client Types](docs/crossplane/keycloak.md#client-types) for CONFIDENTIAL vs PUBLIC client configurations
- **[OpenBao Configuration](docs/crossplane/openbao.md)** - Auth backends, secrets engines, and policies
- **[SSO Integration](docs/crossplane/sso-integration.md)** - Complete Keycloak ↔ OpenBao integration guide
- **[Provider Configurations](docs/crossplane/provider-configs.md)** - Setting up Crossplane providers
- **[Crossplane Initialization](docs/crossplane/initialization.md)** - Provider and function installation
- **[External Secrets](docs/crossplane/external-secrets.md)** - Syncing secrets from OpenBao to Kubernetes

#### Quick Reference

1. **Provider Configuration**: Include credentials reference

   ```yaml
   apiVersion: vault.upbound.io/v1beta1
   kind: ProviderConfig
   metadata:
     name: bao-hnatekmar-xyz
   spec:
     address: https://bao.hnatekmar.xyz
     credentials:
       source: Secret
       secretRef:
         name: openbao-hnatekmar-xyz
         namespace: crossplane-system
         key: config
   ```

2. **Compositions**: Organize by service type (auth, clusters, ssh, etc.)
3. **Keycloak Client Types**: See [Keycloak Configuration](docs/crossplane/keycloak.md) for PKCE (for CLIs) and CONFIDENTIAL (for services) clients

### Error Handling

1. **Resource Limits**: Always specify for production workloads

   ```yaml
   resources:
     limits:
       cpu: 200m
       memory: 500Mi
     requests:
       cpu: 100m
       memory: 200Mi
   ```

2. **Tolerations**: Handle control-plane scheduling when needed

   ```yaml
   tolerations:
     - key: node-role.kubernetes.io/control-plane
       operator: Exists
       effect: NoSchedule
   ```

3. **Health Checks**: Enable for all services

   ```yaml
   extraEnv: |
     - name: KC_HEALTH_ENABLED
       value: "true"
   ```

### Security Best Practices

1. **Secrets**: Never hardcode credentials; use Kubernetes secrets
2. **TLS**: Always use TLS for external endpoints

   ```yaml
   tls:
     - hosts:
         - bao.hnatekmar.xyz
       secretName: bao-secret
   ```

3. **RBAC**: Define appropriate service accounts and roles
4. **Network Policies**: Restrict pod-to-pod communication

## Git Commit Conventions

Follow conventional commits:

```
feat: Add new OpenBao SSH backend
fix: Correct Keycloak ingress configuration
chore: Update Crossplane provider versions
```

## Environment Setup

```bash
# Required environment variables
export KUBECONFIG=~/.kube/hetzner
export VAULT_ADDR=https://bao.hnatekmar.xyz
```

## Common Workflows

### Adding a New Application

1. Create ArgoCD Application manifest in `argocd/`
2. Configure appropriate sync wave
3. Set up namespace and RBAC
4. Test with `kubectl apply --dry-run=server`
5. Commit and let ArgoCD sync

### Updating Provider Versions

1. Check available versions in provider documentation
2. Update `targetRevision` in Helm sources
3. Update Crossplane provider images
4. Test compatibility before deploying

### Adding Project SSO

See [docs/workflows/adding-project-sso.md](docs/workflows/adding-project-sso.md) for complete instructions.

## Troubleshooting

```bash
# Check ArgoCD app health
kubectl get app <app-name> -n argocd -o yaml

# View Crossplane resources
kubectl get managed -A

# Check pod logs
kubectl logs -n <namespace> -l app=<app-name>

# Describe resource for events
kubectl describe <kind>/<name> -n <namespace>
```

## External References

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Kubernetes API Reference](https://kubernetes.io/docs/reference/)
- [Helm Chart Documentation](https://artifacthub.io/)