# AGENTS.md - Guidelines for AI Coding Agents

This document provides instructions for AI agents working on this Hetzner Kubernetes GitOps repository.

## Project Overview

This repository manages Kubernetes infrastructure using:
- **ArgoCD**: GitOps controller for application deployment
- **Crossplane**: Cloud resource provisioning (OpenBao/Vault, Keycloak, DigitalOcean)
- **Helm Charts**: Package management for Kubernetes applications
- **Kubernetes**: Container orchestration on Hetzner Cloud

## Directory Structure

```
├── argocd/              # ArgoCD Application definitions
│   ├── cert-manager/    # SSL/TLS certificate management
│   ├── crossplane/      # Crossplane deployment
│   ├── external-secrets/# External Secrets Operator
│   ├── openbao/         # OpenBao (Vault) Helm chart values
│   ├── configurations/  # Crossplane configurations
│   └── *.yaml           # Application definitions (keycloak, kong, etc.)
├── crossplane/          # Crossplane resources
│   ├── config/          # Provider configurations and compositions
│   ├── init/            # Initial provider setup
│   └── secrets/         # Secret definitions
├── init.yaml            # Root ArgoCD application
└── pod.yaml             # Example pod definitions
```

## Commands

### Prerequisites
```bash
# Load environment variables
direnv allow

# Verify kubectl access
kubectl cluster-info

# Check ArgoCD apps
argocd app list

# Check Crossplane providers
kubectl get providers -A
```

### Validation Commands
```bash
# Validate YAML syntax
find . -name "*.yaml" -exec yamllint {} \;

# Dry-run Kubernetes manifests
kubectl apply --dry-run=client -f <file>.yaml

# Check ArgoCD sync status
argocd app sync <app-name> --dry-run

# Validate Crossplane compositions
kubectl explain <kind>
```

### Running Tests
This repository uses declarative YAML manifests rather than traditional tests. Validation is done through:
```bash
# Kubectl server-side dry-run
kubectl apply --dry-run=server -f <manifest>.yaml

# ArgoCD sync with prune
argocd app sync <app-name> --prune --dry-run
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

### ArgoCD CLI Examples
```bash
# Get app details
argocd app get <app-name>

# Sync an application
argocd app sync <app-name>

# Force sync (if out of sync)
argocd app sync <app-name> --force

# Rollback
argocd app rollback <app-name> <revision>
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

3. **Keycloak Client Configuration**:
   
   **Location**: `crossplane/config/keycloak/clients/<client-name>.yaml`
   
   **PKCE Client (for CLI support)**:
   ```yaml
   apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
   kind: Client
   metadata:
     name: <client-name>
     annotations:
       argocd.argoproj.io/sync-wave: "2"
   spec:
     writeConnectionSecretToRef:
       namespace: crossplane-system
       name: <client-name>-oidc-creds
     providerConfigRef:
       name: sso-hnatekmar-xyz
     forProvider:
       accessType: PUBLIC
       clientId: <client-name>
       standardFlowEnabled: true
       directAccessGrantsEnabled: true
       enabled: true
       realmId: master
       webOrigins:
         - https://<client-domain>
       validRedirectUris:
         - https://<client-domain>/auth/callback
         - http://localhost:8085/auth/callback
       pkceCodeChallengeMethod: S256
   ```
   
   **CONFIDENTIAL Client (server-to-server)**:
   ```yaml
   apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
   kind: Client
   metadata:
     name: <client-name>
   spec:
     writeConnectionSecretToRef:
       namespace: crossplane-system
       name: <client-name>-creds
     providerConfigRef:
       name: sso-hnatekmar-xyz
     forProvider:
       accessType: CONFIDENTIAL
       clientId: <client-name>
       standardFlowEnabled: true
       enabled: true
       realmId: master
       webOrigins:
         - https://<client-domain>
       validRedirectUris:
         - https://<client-domain>/auth/callback
   ```
   
   **Example Integration with ArgoCD**:
   ```yaml
   configs:
     cm:
       oidc.config: |
         name: Keycloak
         issuer: https://sso.hnatekmar.xyz/realms/master
         clientID: <client-name>
         clientSecret: $<client-name>-oidc-creds:clientSecret
         enablePKCEAuthentication: true
   ```

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

### Git Commit Conventions

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

### Troubleshooting
```bash
# Check ArgoCD app health
argocd app get <app-name> -o yaml

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
