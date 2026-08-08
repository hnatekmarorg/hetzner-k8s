# OpenBao Configuration Guide

This document describes how to configure OpenBao (Vault) resources using Crossplane. All OpenBao resources use the `vault.upbound.io` provider.

## Resource Types

### Auth Backend (jwt.vault.upbound.io/v1alpha1)

Configures an authentication method in OpenBao. The most common is OIDC authentication for SSO integration.

**Example**: `crossplane/config/bao/bao-hnatekmar-xyz/sso/backend.yaml`

```yaml
apiVersion: jwt.vault.upbound.io/v1alpha1
kind: AuthBackend
metadata:
  name: sso
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    path: oidc
    type: oidc
    defaultRole: sso
    oidcClientId: bao-hnatekmar-xyz
    oidcClientSecretSecretRef:
      key: attribute.client_secret
      namespace: crossplane-system
      name: bao-hnatekmar-xyz
    oidcDiscoveryUrl: https://sso.hnatekmar.xyz/realms/master
```

**Key Fields**:
- `forProvider.path`: Mount path in OpenBao (e.g., `oidc`)
- `forProvider.type`: Auth method type (`oidc`, `kubernetes`, `userpass`, etc.)
- `forProvider.defaultRole`: Default role to use if none is specified
- `oidcClientId`: Client ID from Keycloak
- `oidcClientSecretSecretRef`: Reference to secret containing client secret
- `oidcDiscoveryUrl`: Keycloak OIDC discovery URL

### Auth Backend Role (jwt.vault.upbound.io/v1alpha1)

Defines a role within an OIDC auth backend, mapping Keycloak groups/claims to OpenBao policies and token settings.

**Example**: `crossplane/config/bao/bao-hnatekmar-xyz/sso/roles/hnatekmarorg-base.yaml`

```yaml
apiVersion: jwt.vault.upbound.io/v1alpha1
kind: AuthBackendRole
metadata:
  name: sso-hnatekmarorg-base
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    backendRef:
      name: sso
    userClaim: email
    allowedRedirectUris:
      - https://bao.hnatekmar.xyz/ui/vault/auth/oidc/oidc/callback
      - http://localhost:8250/oidc/callback
    roleName: sso-hnatekmarorg-base
    roleType: oidc
    groupsClaim: groups
    boundClaims:
      groups: "hnatekmarorg-base"
    tokenPolicies:
      - hnatekmarorg-base
    tokenTtl: 3600
    tokenMaxTtl: 14400
    tokenType: "service"
```

**Key Fields**:
- `backendRef.name`: Reference to the AuthBackend
- `userClaim`: Claim containing user identity (e.g., `email`)
- `groupsClaim`: Claim containing groups (e.g., `groups`)
- `boundClaims`: Claims that must match for authentication
  - `groups`: Required Keycloak group membership
- `roleName`: Role name in OpenBao
- `roleType`: Always `oidc` for OIDC auth
- `allowedRedirectUris`: Allowed callback URLs
- `tokenPolicies`: List of OpenBao policies to assign
- `tokenTtl`: Token time-to-live in seconds
- `tokenMaxTtl`: Maximum token TTL in seconds
- `tokenType`: Token type (`service` or `batch`)

### Policy (vault.vault.upbound.io/v1alpha1)

Defines an OpenBao policy that controls access to secrets and paths.

**Example**: `crossplane/config/bao/bao-hnatekmar-xyz/hnatekmarorg/policies/base.yaml`

```yaml
apiVersion: vault.vault.upbound.io/v1alpha1
kind: Policy
metadata:
  name: hnatekmarorg-base
  namespace: crossplane-system
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    name: hnatekmarorg-base
    policy: |
      path "hnatekmarorg-ssh/sign/user" {
        capabilities = ["create", "update"]
      }
```

**Policy Language**:
Policies use HCL syntax:
```hcl
path "<path>" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

**Capabilities**:
- `create`: Create data at path
- `read`: Read data at path
- `update`: Update data at path
- `delete`: Delete data at path
- `list`: List keys at path
- `sudo`: Allow privileged operations

### SSH Secrets Engine (jwt.vault.upbound.io/v1alpha1)

Configures an SSH secrets engine for signing SSH certificates.

**Example**: `crossplane/config/bao/bao-hnatekmar-xyz/hnatekmarorg/ssh/ssh-backend.yaml`

```yaml
apiVersion: jwt.vault.upbound.io/v1alpha1
kind: SecretsEngine
metadata:
  name: hnatekmarorg-ssh
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    path: hnatekmarorg-ssh
    type: ssh
```

### Kubernetes Secrets Engine Config

Configures a Kubernetes-based secrets engine for injecting secrets into pods.

**Note**: This is typically configured outside of Crossplane for cluster-specific access.

---

## Secret Organization Convention

The OpenBao config lives at `crossplane/config/bao/bao-hnatekmar-xyz/`. Follow these rules when adding/modifying resources:

1. **Directory = tenant.** One directory per KV mount/tenant holding its own `mount.yaml`, `policies/`, optional `ssh/`, and a `README.md` acting as that mount's **secret registry** (paths + purpose + consumers — never values).
2. **Auth** lives centrally: `auth/` for backends, `roles/{kubernetes,approle,oidc}/` for roles. File name == resource identity.
3. **Naming:** `metadata.name` == `forProvider.name` == file name.
4. **Policy scoping:** policies grant their **own mount only**. Cross-mount access uses a dedicated reader policy + role — never widen a tenant policy (e.g. `algovectra` must not grant `hermes/*`).
5. **Per-tenant agents:** each tenant gets a `*-agent` identity (kubernetes SA + policy) scoped to its own mount. Add agents for new consumers instead of widening existing roles.
6. **KV path scheme:** `<mount>/<service>/<secret>` (CLI). The internal `/data/` segment is a CLI↔API detail, not part of the documented path.
7. **Every new secret** gets a registry row + an explicit policy gate.

**Argo/Crossplane caveat:** renaming a resource = delete + recreate. Prefer file moves (no-ops) over renames; keep login identities (`roleName` for approle/oidc, kubernetes role names referenced by ESO stores) stable unless deliberately recreated.
