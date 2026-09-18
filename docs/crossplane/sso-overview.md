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
| Grafana | https://monitoring-hetzner.hnatekmar.xyz | `grafana-hnatekmar-xyz` | OIDC (authorization code) | Grafana `role_attribute_path`: `algovectra` + `hnatekmarorg-admin` → Admin |
| `kubectl-hnatekmar-xyz` | kubectl / kubeconfig | PUBLIC | `http://localhost:8000`, `http://localhost:18000` |
| kubectl (kubeconfig) | — (CLI) | `kubectl-hnatekmar-xyz` | OIDC + PKCE via `kubelogin` | Kubernetes RBAC, from the token's `groups` claim |

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
| `grafana-hnatekmar-xyz` | Grafana | CONFIDENTIAL | `https://monitoring-hetzner.hnatekmar.xyz/login/generic_oauth` |

- Manifests: `crossplane/config/keycloak/clients/*.yaml`
- `kubectl-hnatekmar-xyz` is the only PUBLIC client here: PKCE instead of a secret, so there is
  nothing to sync into a namespace and no `writeConnectionSecretToRef` on the resource.
- Client secrets are written to connection secrets and synced into the service namespace via ExternalSecrets (see `argocd/argocd-external-secret.yaml`, `argocd/argocd-bootstrap-external-secret.yaml`).

## Kubernetes Cluster Access

Cluster access is scoped by how much the cluster matters. Every cluster belongs to **one class** and
binds **only that class's roles**, so holding the other class's role grants nothing there:

| Class | Clusters | Realm roles | ClusterRole |
|-------|----------|-------------|-------------|
| `infra` | bootstrap, devops/prod — clusters that must keep working | `k8s-infra-viewer` / `k8s-infra-admin` | `view` / `cluster-admin` |
| `dev` | sandbox — free to break | `k8s-dev-viewer` / `k8s-dev-admin` | `view` / `cluster-admin` |

The split is deliberate: the role that lets you break a sandbox freely (`k8s-dev-admin`) is **not** the
role that touches the cluster everything else depends on (`k8s-infra-admin`).

Both tiers use built-in ClusterRoles (`view`, `cluster-admin`) — no custom roles to audit.

**Realm roles, not groups.** A Keycloak group does not reach a token unless a mapper adds it: the
`groups` claim arrives via the `microprofile-jwt` scope (which is why it is required for OpenBao).
Realm roles arrive through the built-in `roles` scope as `realm_access.roles`, which every client
includes, so roles are what a cluster can reliably read.

That has one consequence: `realm_access.roles` is a **nested** claim. The legacy `--oidc-*` flags
configure a top-level claim only, so clusters use the structured `--authentication-config` with a
claim expression and the `sso:` prefix.

**How the roles reach the cluster.** Kubernetes' OIDC authenticator reads TOP-LEVEL claims only, and
realm roles are nested under `realm_access.roles`. The structured `AuthenticationConfiguration` that
could read a nested claim is not usable on Talos 1.14 (the file cannot be made visible inside the
kube-apiserver static pod — siderolabs/talos#14394), so the claim is flattened on the Keycloak side by
an explicit protocol mapper:

```
kubectl-hnatekmar-xyz  --ProtocolMapper-->  k8s-roles (top-level, multi-valued)
```

The mapper sets `id.token.claim`, which is the one that matters: kubectl presents the ID token. A mapper
that populated only the access token would produce credentials that authenticate but carry no roles,
which looks exactly like an RBAC misconfiguration.

Manifests: `crossplane/config/keycloak/clients/kubectl-mapper-k8s-roles.yaml`.

Manifests: `crossplane/config/keycloak/roles/k8s-*.yaml`. Assignment is either direct or via a
group -> role mapping (`group.keycloak.crossplane.io/v1alpha1` `Roles`), if group-based membership
management is preferred.

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

## Grafana Access

Grafana authenticates via the `grafana-hnatekmar-xyz` OIDC client (generic OAuth) and maps the token's `groups` claim (realm roles emitted by the microprofile-jwt scope) to an org role using `role_attribute_path` (`argocd/monitoring/kube-prometheus-stack.yaml`):

| Keycloak Realm Role | Grafana Org Role |
|---------------------|------------------|
| `algovectra` | Admin |
| `hnatekmarorg-admin` | Admin |

Only members of those two roles can sign in (strict role mapping); all other logins are denied. Local login form and initial admin creation are disabled, so SSO is the only way in. The Grafana client secret is propagated from the Crossplane connection secret `crossplane-system/grafana-hnatekmar-xyz` to the `monitoring` namespace via a `kubernetes` ClusterSecretStore (`crossplane/config/eso/secretStore/kubernetes-crossplane.yaml`) and an ExternalSecret (`monitoring/external-secret.yaml`).

## Known Gaps

1. **`hnatekmarorg-admin` group has no OpenBao OIDC role.** The group, realm role, and policy (`hnatekmarorg-admin`) exist, but no OIDC role binds to `groups: "hnatekmarorg-admin"`. Members get no OpenBao SSO access unless they are also in `hnatekmarorg-base`. Add an OIDC role (or extend `hnatekmarorg`) to grant admin SSH access.
2. **OpenBao admin/role bindings rely on the `groups` claim, which microprofile-jwt populates with realm roles.** The `hnatekmarorg` OIDC role binds `groups: "hnatekmarorg-base"` (a group name) but the mapper emits realm roles (e.g. `hnatekmarorg`), so only the `algovectra` binding matches by coincidence. OpenBao access is being redesigned (deferred).

## Adding SSO for a New Service

See [Adding Project SSO Guide](../workflows/adding-project-sso.md) for the full step-by-step workflow.
