# Adding Project SSO Guide

This guide explains how to add SSO access for a new project using Keycloak and OpenBao integration.

## Overview

When adding a new project, you need to set up:
1. Keycloak group for project users
2. Keycloak realm role for the project
3. Group-to-role mapping
4. OpenBao OIDC role for SSO authentication
5. OpenBao policy for project-specific secrets
6. OpenBao SSH secrets engine (if SSH access is needed)

## Prerequisites

- Access to Keycloak and OpenBao via Crossplane
- Existing SSO integration configured (Keycloak OIDC client, OpenBao OIDC backend)
- Decision on access levels (e.g., base, admin)

## Step-by-Step Process

### Step 1: Gather Information

Determine the following:
- **Project name**: `myproject`
- **Domain**: If applicable (e.g., `myproject.example.com`)
- **Access levels**: Typically `base` and `admin`
- **Secrets needed**: SSH certificates, API keys, database credentials, etc.

### Step 2: Create Keycloak Group

Create a Keycloak group for each access level.

**File**: `crossplane/config/keycloak/groups/myproject-base.yaml`

```yaml
---
# Keycloak Group for myproject Base Users
# Users added to this group can request SSH certificates
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Group
metadata:
  name: myproject-base
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: myproject-base
    realmId: master
```

Repeat for `myproject-admin` if needed.

### Step 3: Create Keycloak Realm Role

Create a realm role for each access level.

**File**: `crossplane/config/keycloak/roles/myproject-base-realm.yaml`

```yaml
---
# Realm role for myproject base users
# This role grants access to sign user SSH certificates
apiVersion: role.keycloak.crossplane.io/v1alpha1
kind: Role
metadata:
  name: myproject-base-realm-role
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: myproject-base
    realmId: master
    description: "Base role for myproject SSH certificate access"
```

Repeat for `myproject-admin` if needed.

### Step 4: Map Group to Role

Create a mapping between the group and role.

**File**: `crossplane/config/keycloak/roles/myproject-base-mapping.yaml`

```yaml
---
# Map myproject-base group to its client role
# Users in this group will automatically get the myproject-base role
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Roles
metadata:
  name: myproject-base-roles
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    groupIdRef:
      name: myproject-base
    realmId: master
    roleIdsRefs:
      - name: myproject-base-role
    exhaustive: true
```

### Step 5: Create OpenBao OIDC Role

Create an OIDC role in OpenBao that maps Keycloak group to OpenBao policies.

**File**: `crossplane/config/bao/bao-hnatekmar-xyz/sso/roles/myproject-base.yaml`

```yaml
---
# SSO Role for myproject base users (using realm role)
# Users with myproject-base group get the myproject-base realm role
apiVersion: jwt.vault.upbound.io/v1alpha1
kind: AuthBackendRole
metadata:
  name: sso-myproject-base
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
    roleName: sso-myproject-base
    roleType: oidc
    groupsClaim: groups
    boundClaims:
      groups: "myproject-base"
    tokenPolicies:
      - myproject-base
    tokenTtl: 3600
    tokenMaxTtl: 14400
    tokenType: "service"
```

### Step 6: Create OpenBao Policy

Define what secrets the project can access.

**File**: `crossplane/config/bao/bao-hnatekmar-xyz/myproject/policies/base.yaml`

```yaml
apiVersion: vault.vault.upbound.io/v1alpha1
kind: Policy
metadata:
  name: myproject-base
  namespace: crossplane-system
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    name: myproject-base
    policy: |
      path "myproject-ssh/sign/user" {
        capabilities = ["create", "update"]
      }
```

**Note**: If this is the first secret engine for the project, you may need to create a ClusterSecretStore for accessing project secrets:

**File**: `crossplane/config/eso/secretStore/local-stores.yaml` (append)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: local-myproject
spec:
  provider:
    vault:
      server: https://bao.hnatekmar.xyz
      path: "myproject"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
          role: "bao-hnatekmar-xyz"
```

### Step 7: Create SSH Secrets Engine (If Needed)

If the project requires SSH certificate signing:

**File**: `crossplane/config/bao/bao-hnatekmar-xyz/myproject/ssh/ssh-backend.yaml`

```yaml
apiVersion: jwt.vault.upbound.io/v1alpha1
kind: SecretsEngine
metadata:
  name: myproject-ssh
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    path: myproject-ssh
    type: ssh
```

You may also need to configure SSH roles and CA keys. This is typically done directly in OpenBao or through additional Crossplane resources.

### Step 8: Test the Configuration

Apply the new resources:

```bash
kubectl apply -f crossplane/config/keycloak/groups/myproject-base.yaml
kubectl apply -f crossplane/config/keycloak/roles/myproject-base-realm.yaml
kubectl apply -f crossplane/config/keycloak/roles/myproject-base-mapping.yaml
kubectl apply -f crossplane/config/bao/bao-hnatekmar-xyz/sso/roles/myproject-base.yaml
kubectl apply -f crossplane/config/bao/bao-hnatekmar-xyz/myproject/policies/base.yaml
```

Verify resources are created:

```bash
kubectl get group myproject-base -n crossplane-system
kubectl get role myproject-base-realm-role -n crossplane-system
kubectl get authbackendrole sso-myproject-base -n crossplane-system
kubectl get policy myproject-base -n crossplane-system
```

### Step 9: Test User Access

1. Add a test user to the Keycloak group via Keycloak UI
2. Have the user log in to OpenBao at `https://bao.hnatekmar.xyz`
3. Verify the user can access secrets defined by the policy

## Admin Access

For admin-level access, repeat the steps replacing `base` with `admin`:

- Create `myproject-admin` group
- Create `myproject-admin` realm role
- Map group to role
- Create `sso-myproject-admin` OIDC role with broader privileges
- Create `myproject-admin` policy with additional capabilities

Example admin policy:

```hcl
path "myproject-ssh/sign/user" {
  capabilities = ["create", "update", "list", "sudo"]
}
path "myproject-ssh/config/*" {
  capabilities = ["read", "list"]
}
```

## Cleanup

To remove a project's SSO access:

```bash
kubectl delete group myproject-base -n crossplane-system
kubectl delete role myproject-base-realm-role -n crossplane-system
kubectl delete group.roles myproject-base-roles -n crossplane-system
kubectl delete authbackendrole sso-myproject-base -n crossplane-system
kubectl delete policy myproject-base -n crossplane-system
```

Remove users from the Keycloak group via Keycloak UI.

## Troubleshooting

- **User can't authenticate**: Verify group membership in Keycloak UI
- **Wrong policies assigned**: Check `boundClaims.groups` matches Keycloak group name
- **No secret access**: Verify policy grants access to the correct paths
- **OIDC role not found**: Check that OIDC backend is configured correctly

See [troubleshooting.md](troubleshooting.md) for more issues.
