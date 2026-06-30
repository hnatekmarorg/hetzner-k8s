# ArgoCD Applications

This directory contains the ArgoCD Application manifests and supporting resources for the Hetzner Kubernetes GitOps setup.

## Directory Layout

```
argocd/
├── apps/                    # ArgoCD Application CRDs (the "app-of-apps" children)
│   ├── platform/            # Core platform services (sync-wave -1 to 2)
│   ├── services/            # Application services (sync-wave -2 to 1)
│   └── config/              # Crossplane configuration apps (sync-wave 3-4)
├── manifests/               # Plain Kubernetes manifests (Ingresses, ExternalSecrets, RBAC)
├── values/                  # Helm values files referenced by Application manifests
├── appsets/                 # ArgoCD ApplicationSets (multi-cluster/environment patterns)
└── README.md
```

All manifests in this directory are deployed by the root [`init.yaml`](../init.yaml) (App-of-Apps pattern) which points to `path: argocd` with `recurse: true`.

## Sync-Wave Dependency Graph

Sync waves control deployment ordering. Lower waves deploy first.

```
Wave -2  │ keycloak-postgresql        PostgreSQL database for Keycloak
         │
Wave -1  │ openbao                    OpenBao (Vault) secrets engine
         │
Wave 0   │ argocd, argocd-bootstrap   ArgoCD itself (must come early)
         │ cert-manager               TLS certificate management
         │
Wave 1   │ external-secrets           External Secrets Operator
         │ keycloakx                  Keycloak SSO / identity provider
         │ kubernetes_ingress         K8s API OIDC proxy ingress
         │ label-oidc-secret-job      OIDC secret labeling (PostSync hook)
         │
Wave 2   │ crossplane                 Crossplane control plane
         │ kong                       Kong API gateway
         │
Wave 3   │ crossplane-init            Crossplane providers & functions
         │
Wave 4   │ crossplane-config          Crossplane provider configs & compositions
         │ crossplane-secrets         Crossplane-managed ExternalSecrets
         │
Wave 10  │ argocd-ingress             ArgoCD ingress via Kong
         │
Wave 15  │ argocd-oidc-secret         OIDC client secrets (ExternalSecrets)
         │ argocd-bootstrap-oidc-secret
```

### Dependency Rules

- **Wave -2 to -1**: Infrastructure foundations (database, secrets engine)
- **Wave 0-2**: Core platform (ArgoCD, cert-manager, Crossplane, Kong)
- **Wave 3-4**: Crossplane configuration (providers, configs, secrets)
- **Wave 10+**: Final wiring (ingresses, secrets sync)

## Adding a New Application

1. Create the Application manifest in the appropriate `apps/` sub-directory
2. Assign a sync-wave annotation based on dependencies
3. Add supporting manifests (Ingress, ExternalSecret, RBAC) to `manifests/`
4. Add Helm values files to `values/` if needed
5. Update this README's sync-wave table
6. Commit and let ArgoCD auto-sync

## Notes

- The root [`init.yaml`](../init.yaml) at the repo root is the **single entry point**. Do not create additional App-of-Apps manifests.
- All Applications use `automated.syncPolicy` with `prune: true` and `selfHeal: true` unless noted otherwise.
- Crossplane resources (providers, configs, compositions, claims) live in [`crossplane/`](../crossplane/) and are deployed by `crossplane-init`, `crossplane-config`, and `crossplane-secrets` Applications.
