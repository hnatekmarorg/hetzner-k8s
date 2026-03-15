# External Secrets Configuration Guide

This document describes how to configure the External Secrets Operator to sync secrets from OpenBao to Kubernetes.

## Overview

External Secrets Operator (ESO) connects external secret stores to Kubernetes, syncing secrets into the cluster. This repository uses ESO with OpenBao (Vault) as the secret backend.

## Architecture

```
OpenBao (Vault) → External Secrets Operator → Kubernetes Secrets → Pods
```

## Resource Types

### ClusterSecretStore (external-secrets.io/v1)

Defines a secret store configuration available cluster-wide.

**Example**: `crossplane/config/eso/secretStore/local-stores.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: local
spec:
  provider:
    vault:
      server: https://bao.hnatekmar.xyz
      path: "clusters"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
          role: "bao-hnatekmar-xyz"
```

**Key Fields**:
- `metadata.name`: Name used by ExternalSecrets to reference this store
- `provider.vault.server`: OpenBao server URL
- `provider.vault.path`: Secret engine mount path in OpenBao
- `provider.vault.version`: Vault API version (`v1` or `v2`)
- `provider.vault.auth.kubernetes`: Kubernetes authentication method
  - `mountPath`: Path where Kubernetes auth method is mounted in OpenBao
  - `serviceAccountRef`: Service account for this cluster
  - `role`: Role name in OpenBao's Kubernetes auth backend

### ExternalSecret (external-secrets.io/v1)

Syncs secrets from OpenBao to Kubernetes.

**Example**: `crossplane/config/providers/sso-hnatekmar-xyz.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: sso-hnatekmar-xyz
  namespace: crossplane-system
spec:
  refreshInterval: "15s"
  secretStoreRef:
    name: local
    kind: ClusterSecretStore
  target:
    name: sso-hnatekmar-xyz
    template:
      engineVersion: v2
      data:
        config: |
          {
            "url": "https://sso.hnatekmar.xyz",
            "client_id": "admin-cli",
            "username": "{{ .username }}",
            "password": "{{ .password }}"
          }
  data:
    - secretKey: username
      remoteRef:
        key: /admin/keycloak
        property: username
    - secretKey: password
      remoteRef:
        key: /admin/keycloak
        property: password
```

**Key Fields**:
- `metadata.name`: Name of this ExternalSecret resource
- `spec.refreshInterval`: How often to refresh secrets (e.g., `15s`, `1h`)
- `spec.secretStoreRef`: Reference to ClusterSecretStore
- `spec.target`: The Kubernetes secret to create/update
  - `name`: Target secret name in Kubernetes
  - `template`: Optional template to transform fetched data
    - `engineVersion`: Template engine version
    - `data`: Template data references (e.g., `{{ .username }}`)
- `spec.data`: Fields to sync
  - `secretKey`: Key in Kubernetes secret
  - `remoteRef`: Reference in OpenBao
    - `key`: OpenB secret path (e.g., `/admin/keycloak`)
    - `property`: Property within the secret (for v2 KV)

## OpenBao Kubernetes Auth Backend

For External Secrets to work, OpenBao must have a Kubernetes auth backend configured:

```yaml
apiVersion: kubernetes.vault.upbound.io/v1alpha1
kind: AuthBackend
metadata:
  name: kubernetes
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    type: kubernetes
    path: kubernetes
```

And a role for the external-secrets service account:

```yaml
apiVersion: kubernetes.vault.upbound.io/v1alpha1
kind: AuthBackendRole
metadata:
  name: external-secrets
  namespace: crossplane-system
spec:
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    backendRef:
      name: kubernetes
    boundServiceAccountNames:
      - external-secrets
    boundServiceAccountNamespaces:
      - external-secrets
    roleName: external-secrets
    tokenTtl: 43200
    tokenMaxTtl: 86400
    tokenPolicies:
      - external-secrets
```

The associated policy grants access to required secrets:

```yaml
apiVersion: vault.vault.upbound.io/v1alpha1
kind: Policy
metadata:
  name: external-secrets
  namespace: crossplane-system
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: bao-hnatekmar-xyz
  forProvider:
    name: external-secrets
    policy: |
      path "clusters/*" {
        capabilities = ["read", "list"]
      }
```

## Usage Patterns

### Sync Individual Secret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-secret
spec:
  secretStoreRef:
    name: local
    kind: ClusterSecretStore
  target:
    name: my-secret
  data:
    - secretKey: apikey
      remoteRef:
        key: /services/myapp/apikey
```

### Transform Secret with Template

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-config
spec:
  secretStoreRef:
    name: local
    kind: ClusterSecretStore
  target:
    name: my-config
    template:
      engineVersion: v2
      data:
        DATABASE_URL: "postgresql://{{ .user }}:{{ .password }}@{{ .host }}:5432/{{ .db }}"
  data:
    - secretKey: user
      remoteRef:
        key: /database/credentials
        property: user
    - secretKey: password
      remoteRef:
        key: /database/credentials
        property: password
    - secretKey: host
      remoteRef:
        key: /database/credentials
        property: host
    - secretKey: db
      remoteRef:
        key: /database/credentials
        property: database
```

## Managing External Secrets

### List External Secrets

```bash
kubectl get externalsecret -A
```

### View Synced Secrets

```bash
kubectl get secret -n <namespace>
kubectl get secret <secret-name> -n <namespace> -o yaml
```

### Check Sync Status

```bash
kubectl get externalsecret <name> -n <namespace> -o yaml
```

Look for `status.conditions` to see sync status.

### Force Refresh

External Secrets automatically refresh based on `refreshInterval`. To force immediate refresh:

```bash
kubectl annotate externalsecret <name> -n <namespace> force-sync=$(date +%s)
```

## Troubleshooting

### ExternalSecret Not Syncing

**Symptom**: Kubernetes secret not created or not updating

**Checklist**:
1. ClusterSecretStore exists and is healthy:
   ```bash
   kubectl get clustersecretstore
   ```

2. Service account has correct role in OpenBao

3. Secret path exists in OpenBao:
   ```bash
   bao kv get -mount=clusters /admin/keycloak
   ```

4. Check ExternalSecret status:
   ```bash
   kubectl describe externalsecret <name> -n <namespace>
   ```

### Service Account Permission Issues

**Symptom**: Access denied errors

**Solution**:
1. Verify service account exists: `kubectl get sa -n external-secrets`
2. Verify role exists in OpenBao Kubernetes auth backend
3. Verify role grants access to secret path

### KV Version Mismatch

**Symptom**: Secret not found or retrieval errors

**Solution**: Ensure `version: "v2"` in ClusterSecretStore matches OpenBao KV secrets engine version

### Template Not Rendering

**Symptom**: Template values showing as empty or literal template

**Solution**:
1. Verify remoteRef keys and properties are correct
2. Use correct syntax: `{{ .keyName }}`
3. Check secret data structure in OpenBao
