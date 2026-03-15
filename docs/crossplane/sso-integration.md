# SSO Integration Guide

This document explains the complete SSO integration between Keycloak and OpenBao, enabling single sign-on for secret access.

## Architecture Overview

The integration links Keycloak groups to OpenBao policies through a chain of resources:

```
Keycloak Group → Keycloak Realm Role → OpenBao OIDC Role → OpenBao Policy
```

This allows users to authenticate once via Keycloak and automatically receive appropriate OpenBao token permissions.

## Complete Flow

### 1. User Authentication in Keycloak

Users authenticate to Keycloak using any supported method (SSO, username/password, etc.).

### 2. Group Membership

When a user belongs to a Keycloak group, they receive the corresponding realm role through group-role mapping.

**Example**: User in `hnatekmarorg-base` group → Receives `hnatekmarorg-base` realm role

### 3. OIDC Authentication to OpenBao

User accesses OpenBao, which redirects to Keycloak for OIDC authentication. Keycloak issues an ID token containing:
- `email`: User's email address
- `groups`: List of Keycloak groups the user belongs to

### 4. OpenBao OIDC Role Mapping

OpenBao's OIDC auth backend validates the token and maps the user to an OIDC role based on:

- **Bound Claims**: Claims that must match (typically a specific group)
- **Token Policies**: OpenBao policies to assign to the token

**Example**: `sso-hnatekmarorg-base` OIDC role requires `boundClaims.groups = "hnatekmarorg-base"` and assigns `hnatekmarorg-base` policy

### 5. Policy-Based Access

The assigned OpenBao policy controls what secrets the user can access.

**Example**: `hnatekmarorg-base` policy allows signing SSH certificates under `hnatekmarorg-ssh/sign/user`

## Configuration Steps

### Step 1: Create Keycloak Client

Define an OIDC client in Keycloak that OpenBao will use.

**Example**: `crossplane/config/keycloak/clients/bao-client.yaml`

```yaml
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: Client
metadata:
  name: bao-hnatekmar-xyz
spec:
  forProvider:
    accessType: CONFIDENTIAL
    clientId: bao-hnatekmar-xyz
    standardFlowEnabled: true
    enabled: true
    realmId: master
    validRedirectUris:
      - https://bao.hnatekmar.xyz/ui/vault/auth/oidc/oidc/callback
```

### Step 2: Configure Keycloak Provider in Crossplane

The Keycloak provider config uses an ExternalSecret to fetch credentials.

**Example**: `crossplane/config/providers/sso-hnatekmar-xyz.yaml`

```yaml
apiVersion: keycloak.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: sso-hnatekmar-xyz
  namespace: crossplane-system
spec:
  credentials:
    secretRef:
      name: sso-hnatekmar-xyz
      key: config
    source: Secret
```

The referenced secret contains the Keycloak admin credential in JSON format.

### Step 3: Create Keycloak Group

Define a group for users who need a specific access level.

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

### Step 4: Create Keycloak Realm Role

Create a realm role that represents the access level.

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
```

### Step 5: Map Group to Role

Connect the group to the role so group members automatically receive it.

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

### Step 6: Configure OpenBao OIDC Backend

Set up OIDC authentication in OpenBao using the Keycloak client credentials.

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

### Step 7: Create OpenBao OIDC Role

Define an OIDC role that maps Keycloak groups to OpenBao policies.

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
    groupsClaim: groups
    boundClaims:
      groups: "hnatekmarorg-base"
    tokenPolicies:
      - hnatekmarorg-base
    tokenTtl: 3600
    tokenMaxTtl: 14400
    tokenType: "service"
```

**Important Fields**:
- `boundClaims.groups`: Keycloak group that users must belong to
- `tokenPolicies`: OpenBao policies to assign to authenticated users

### Step 8: Create OpenBao Policy

Define the actual access control for this level of users.

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

## Naming Convention

For consistency across the integration chain, use matching names:

- **Keycloak Group**: `hnatekmarorg-base`
- **Keycloak Realm Role**: `hnatekmarorg-base`
- **OpenBao OIDC Role**: `sso-hnatekmarorg-base` (prefixed with auth backend name)
- **OpenBao Policy**: `hnatekmarorg-base`

## Testing the Integration

1. **Verify Keycloak Configuration**:
   ```bash
   kubectl get group hnatekmarorg-base -n crossplane-system
   kubectl get role hnatekmarorg-base-role -n crossplane-system
   ```

2. **Verify OpenBao Configuration**:
   ```bash
   kubectl get authbackend sso -n crossplane-system
   kubectl get authbackendrole sso-hnatekmarorg-base -n crossplane-system
   kubectl get policy hnatekmarorg-base -n crossplane-system
   ```

3. **Test SSO Login**: Access `https://bao.hnatekmar.xyz` and verify redirection to Keycloak

## Troubleshooting

- **Users can't authenticate**: Check OIDC client configuration and redirect URIs
- **Wrong policies assigned**: Verify `boundClaims` and `tokenPolicies` in OIDC role
- **Token expired too quickly**: Adjust `tokenTtl` and `tokenMaxTtl` in OIDC role
