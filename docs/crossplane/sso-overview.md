# SSO Overview

Central reference for how single sign-on is organized across the services in this infrastructure. All SSO configuration is managed declaratively via Crossplane resources in `crossplane/config/`.

## Architecture

Keycloak (`sso.hnatekmar.xyz`, `master` realm) is the single identity provider. Users authenticate to Keycloak (via GitHub OAuth identity providers or username/password), then each service trusts Keycloak's issued tokens through an OIDC client.

```
GitHub OAuth ──► Keycloak (master realm) ──┬──► OpenBao   (OIDC client bao-hnatekmar-xyz)
    (IdPs)      (issuer sso.hnatekmar.xyz)  └──► ArgoCD    (OIDC clients argocd-*, argocd-bootstrap-*)
```

For OpenBao, group membership in Keycloak is carried in the token's `groups` claim and mapped to OpenBao policies via OIDC roles:

```
Keycloak Group → Keycloak Realm Role → OpenBao OIDC Role (boundGroups) → OpenBao Policy
```

## Service Matrix

| Service | URL | Keycloak Client | Auth Flow | Access Control |
|---------|-----|-----------------|-----------|----------------|
| Keycloak | https://sso.hnatekmar.xyz | `account`/`admin-cli` (built-in) | Login page, GitHub IdPs | Keycloak admin roles |
| OpenBao | https://bao.hnatekmar.xyz | `bao-hnatekmar-xyz` | OIDC (authorization code) | OpenBao OIDC roles → policies |
| ArgoCD | https://argocd.hnatekmar.xyz/argocd | `argocd-hnatekmar-xyz` | OIDC | ArgoCD RBAC `g, hnatekmarorg-admin, role:admin` |
| ArgoCD Bootstrap | https://argocd-bootstrap.hnatekmar.xyz | `argocd-bootstrap-hnatekmar-xyz` | OIDC | ArgoCD RBAC `g, hnatekmarorg-admin, role:admin` |

## Identity Providers

Users sign in to Keycloak using GitHub OAuth. One identity provider per organization:

| IdP | Alias | Organization | Secrets (OpenBao path) | Kubernetes Secret |
|-----|-------|--------------|------------------------|-------------------|
| GitHub (algovectra) | `github-algovectra` | hnatekmarorg/algovectra | `devops/github/algovectra` | `crossplane-system/github-algovectra` |
| GitHub (hnatekmarorg) | `github-hnatekmarorg` | hnatekmarorg | `devops/github/hnatekmarorg` | `crossplane-system/github-hnatekmarorg` |

- Manifests: `crossplane/config/keycloak/identity-providers/*.yaml`
- ExternalSecrets: `crossplane/config/eso/github-*.yaml` (via `local-devops` ClusterSecretStore)

Both providers sync GitHub username and email into the Keycloak user profile.

## Keycloak Clients

| Client ID | Service | Type | Redirect URIs |
|-----------|---------|------|---------------|
| `bao-hnatekmar-xyz` | OpenBao | CONFIDENTIAL | `https://bao.hnatekmar.xyz/ui/vault/auth/oidc/oidc/callback`, `http://localhost:8250/oidc/callback` |
| `argocd-hnatekmar-xyz` | ArgoCD | CONFIDENTIAL | `https://argocd.hnatekmar.xyz/argocd/auth/callback`, `http://localhost:8080/argocd/auth/callback` |
| `argocd-bootstrap-hnatekmar-xyz` | ArgoCD Bootstrap | CONFIDENTIAL | `https://argocd-bootstrap.hnatekmar.xyz/auth/callback`, `http://localhost:8080/auth/callback` |

- Manifests: `crossplane/config/keycloak/clients/*.yaml`
- Client secrets are written to connection secrets and synced into the service namespace via ExternalSecrets (see `argocd/argocd-external-secret.yaml`, `argocd/argocd-bootstrap-external-secret.yaml`).

## OpenBao Access Levels

OIDC auth backend at `auth/oidc`, discovery `https://sso.hnatekmar.xyz/realms/master`. Each role binds a Keycloak group and assigns policies.

| Keycloak Group | OIDC Role | Bound Group | Policies | Access |
|----------------|-----------|-------------|----------|--------|
| `admin` (manual) | `admin` | `admin` | `admin-identity` | Full access (`*`) |
| `algovectra` | `algovectra` | `algovectra` | `algovectra`, `algovectra-ssh` | algovectra KV + SSH signing |
| `hnatekmarorg-base` | `hnatekmarorg` | `hnatekmarorg-base` | `hnatekmarorg` | hnatekmarorg SSH user signing |

- Roles: `crossplane/config/bao/bao-hnatekmar-xyz/roles/oidc/*.yaml`
- Policies: `crossplane/config/bao/bao-hnatekmar-xyz/{admin,algovectra,hnatekmarorg}/policies/*.yaml`
- Token TTLs: `admin` 24h; `algovectra`, `hnatekmarorg` 1h TTL / 4h max
- Note: The `admin` Keycloak group is created manually (out of band); it is not managed by Crossplane.

## ArgoCD Access

Both ArgoCD instances map OIDC group claims to the built-in `role:admin`:

| Instance | Group → Role | Where |
|----------|--------------|-------|
| ArgoCD | `hnatekmarorg-admin` → `role:admin` | `charts/doks-cluster/values.yaml` |
| ArgoCD Bootstrap | `hnatekmarorg-admin` → `role:admin` | `argocd/argocd-bootstrap.yaml` |

Only the `hnatekmarorg-admin` group has access to ArgoCD (admin level). The `hnatekmarorg-admin` group is also mapped to Keycloak's built-in `admin` realm role, granting admin console access (`crossplane/config/keycloak/roles/hnatekmarorg-admin-keycloak-admin-mapping.yaml`). The legacy `argocd-admins` group has been removed.

## Known Gaps

1. **`hnatekmarorg-admin` group has no OpenBao OIDC role.** The group, realm role, and policy (`hnatekmarorg-admin`) exist, but no OIDC role binds to `groups: "hnatekmarorg-admin"`. Members get no OpenBao SSO access unless they are also in `hnatekmarorg-base`. Add an OIDC role (or extend `hnatekmarorg`) to grant admin SSH access.
2. **OpenBao admin/role bindings rely on the `groups` claim, which microprofile-jwt populates with realm roles.** The `hnatekmarorg` OIDC role binds `groups: "hnatekmarorg-base"` (a group name) but the mapper emits realm roles (e.g. `hnatekmarorg`), so only the `algovectra` binding matches by coincidence. OpenBao access is being redesigned (deferred).

## Adding SSO for a New Service

See [Adding Project SSO Guide](../workflows/adding-project-sso.md) for the full step-by-step workflow.
