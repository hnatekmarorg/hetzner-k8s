# Keycloak Configuration Guide

This document describes how to configure Keycloak resources using Crossplane. All Keycloak resources use the `keycloak.crossplane.io` provider.

## Resource Types

### Group (group.keycloak.crossplane.io/v1alpha1)

Defines a Keycloak group for organizing users. Groups are used to assign roles and permissions.

**Example**: `crossplane/config/keycloak/groups/hnatekmarorg-base.yaml`

```yaml
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Group
metadata:
  name: hnatekmarorg-base
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: hnatekmarorg-base
    realmId: master
```

**Key Fields**:
- `providerConfigRef.name`: Reference to the Keycloak provider config
- `forProvider.name`: Group name in Keycloak
- `forProvider.realmId`: Keycloak realm (typically `master`)

### Role (role.keycloak.crossplane.io/v1alpha1)

Defines a realm role in Keycloak. Roles are assigned to users via group mappings.

**Example**: `crossplane/config/keycloak/roles/hnatekmarorg-base-realm.yaml`

```yaml
apiVersion: role.keycloak.crossplane.io/v1alpha1
kind: Role
metadata:
  name: hnatekmarorg-base-realm-role
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: hnatekmarorg-base
    realmId: master
    description: "Base role for hnatekmarorg SSH certificate access"
```

**Key Fields**:
- `forProvider.name`: Role name in Keycloak
- `forProvider.realmId`: Keycloak realm
- `forProvider.description`: Human-readable description

### Client (openidclient.keycloak.crossplane.io/v1alpha1)

Defines an OIDC client for external applications to authenticate with Keycloak.

**Example**: `crossplane/config/keycloak/clients/bao-client.yaml`

```yaml
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: Client
metadata:
  name: bao-hnatekmar-xyz
spec:
  writeConnectionSecretToRef:
    namespace: crossplane-system
    name: bao-hnatekmar-xyz
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    accessType: CONFIDENTIAL
    clientId: bao-hnatekmar-xyz
    standardFlowEnabled: true
    enabled: true
    realmId: master
    webOrigins:
      - https://bao.hnatekmar.xyz
    validRedirectUris:
      - https://bao.hnatekmar.xyz/ui/vault/auth/oidc/oidc/callback
      - http://localhost:8250/oidc/callback
```

**Client Types**:

1. **CONFIDENTIAL**: For server-to-server communication
   - Requires client secret
   - Use this for backend services like OpenBao

2. **PUBLIC**: For applications like CLIs or SPAs
   - No client secret required
   - Enable `directAccessGrantsEnabled: true` for CLI support
   - Set `pkceCodeChallengeMethod: S256` for PKCE support

**Key Fields**:
- `accessType`: `CONFIDENTIAL` or `PUBLIC`
- `clientId`: Client identifier
- `standardFlowEnabled`: Enable authorization code flow
- `directAccessGrantsEnabled`: Enable direct grant (resource owner password) for CLI tools
- `validRedirectUris`: List of allowed callback URLs
- `webOrigins`: List of allowed CORS origins
- `pkceCodeChallengeMethod`: `S256` for PKCE support (public clients)

### Group Roles (group.keycloak.crossplane.io/v1alpha1)

Maps Keycloak groups to realm roles, automatically assigning roles to group members.

**Example**: `crossplane/config/keycloak/roles/hnatekmarorg-base-mapping.yaml`

```yaml
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Roles
metadata:
  name: hnatekmarorg-base-roles
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    groupIdRef:
      name: hnatekmarorg-base
    realmId: master
    roleIdsRefs:
      - name: hnatekmarorg-base-role
    exhaustive: true
```

**Key Fields**:
- `groupIdRef.name`: Reference to the Group resource
- `roleIdsRefs`: List of roles to assign to group members
- `exhaustive`: If `true`, roles not listed will be removed from the group

- **Wave 4**: Group-to-role mappings

### Client Default Scopes Configuration

When creating OIDC clients for OpenBao/Vault or similar services that require JWT tokens with specific claims, always configure default scopes to ensure required claims are included:

```yaml
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: ClientDefaultScopes
metadata:
  name: <client>-default-scopes
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    clientIdRef:
      name: <client>
    realmId: master
    defaultScopes:
      # Required: email claim for user identification
      - email
      # Required: microprofile-jwt scope for groups in token
      - microprofile-jwt
      # Optional: custom groups scope if additional group mapping is needed
      - <custom-groups-scope>
```

**Required Default Scopes**:

1. **`email`**: Standard OpenID Connect scope that adds the `email` claim to tokens. Required for OpenBao authentication which uses `userClaim: email`.

2. **`microprofile-jwt`**: Keycloak's built-in scope for MicroProfile JWT propagation. Includes groups in the token, required for JWT-based authorization.

**Common Issues**:

- **`claim "email" not found in token`**: The client is missing the `email` default scope. Add `email` to the `ClientDefaultScopes` resource.
- **Groups not in token**: Ensure `microprofile-jwt` is included in default scopes, or create a custom protocol mapper for groups.
