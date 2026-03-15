# Provider Configuration Guide

This document describes how to configure Crossplane providers for managing external resources.

## Overview

Crossplane providers connect Kubernetes to external APIs (Keycloak, OpenBao, DigitalOcean, Kubernetes, Helm). Each provider requires:

1. **Provider installation** (via `pkg.crossplane.io/v1` Provider resource)
2. **Provider configuration** (provider-specific CRD)

## Providers Used

### Keycloak Provider

**Provider Installation**: `crossplane/init/providers/keycloak.yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-keycloak
spec:
  package: xpkg.upbound.io/upbound/provider-keycloak:v1.1.0
```

**Provider Configuration**: `crossplane/config/providers/sso-hnatekmar-xyz.yaml`

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
      namespace: crossplane-system
    source: Secret
```

The referenced secret is created by an ExternalSecret that fetches Keycloak admin credentials from OpenBao:

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
- `credentials.source`: Always `Secret` for credential-based auth
- `credentials.secretRef`: Reference to secret containing credentials
- `credentials.secretRef.key`: Key within the secret containing credential JSON

### OpenBao/Vault Provider

**Provider Installation**: `crossplane/init/providers/vault.yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-vault
spec:
  package: xpkg.upbound.io/upbound/provider-vault:v2.2.2
```

**Provider Configuration**: `crossplane/config/providers/bao-hnatekmar-xyz.yaml`

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

The referenced secret contains Vault authentication credentials (typically Kubernetes JWT or approle credentials).

**Key Fields**:
- `address`: OpenBao server URL
- `credentials.source`: Always `Secret`
- `credentials.secretRef`: Reference to secret containing Vault auth credentials

### DigitalOcean Provider

**Provider Installation**: `crossplane/init/providers/digitalocean.yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-digitalocean
spec:
  package: xpkg.upbound.io/upbound/provider-digitalocean:v0.3.0
```

Provider configuration is organization-specific and follows the same pattern as other providers.

### Kubernetes Provider

**Provider Installation**: `crossplane/init/providers/kubernetes.yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-kubernetes
spec:
  package: xpkg.upbound.io/upbound/provider-kubernetes:v0.10.0
```

Used for managing Kubernetes resources within other clusters.

### Helm Provider

**Provider Installation**: `crossplane/init/providers/helm.yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-helm
spec:
  package: xpkg.upbound.io/upbound/provider-helm:v0.15.0
```

Used for installing and managing Helm charts as Crossplane resources.

## Naming Convention

Provider configurations are named after the service they connect to:
- `sso-hnatekmar-xyz` → Keycloak at `sso.hnatekmar.xyz`
- `bao-hnatekmar-xyz` → OpenBao at `bao.hnatekmar.xyz`

## Managing Providers

### Check Provider Status

```bash
kubectl get providers.crossplane.io -n crossplane-system
```

### Check Provider Configuration

```bash
kubectl get providerconfig -n crossplane-system
kubectl get providerconfig sso-hnatekmar-xyz -n crossplane-system -o yaml
```

### Troubleshooting

- **Provider not healthy**: Check for missing credentials secret
- **Provider can't connect**: Verify service URL is reachable from cluster
- **Provider suspended**: Check account/API quota limits
