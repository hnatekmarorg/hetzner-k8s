# Crossplane Initialization Guide

This document describes the initial setup of Crossplane providers and functions.

## Overview

Crossplane requires providers to be installed and functions to be registered before use. These resources are defined in `crossplane/init/`.

## Directory Structure

```
crossplane/init/
├── providers/        # Provider installations
│   ├── digitalocean.yaml
│   ├── helm.yaml
│   ├── keycloak.yaml
│   ├── kubernetes.yaml
│   └── vault.yaml
└── functions/        # Function packages
    ├── auto-ready.yaml
    └── kcl.yaml
```

## Providers

### Provider (pkg.crossplane.io/v1)

Installs a Crossplane provider from a package repository.

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-vault
spec:
  package: xpkg.upbound.io/upbound/provider-vault:v2.2.2
```

**Key Fields**:
- `metadata.name`: Provider name for reference
- `spec.package`: Package URL with version tag

### Installed Providers

| Name | Version | Purpose |
|------|---------|---------|
| upbound-provider-vault | v2.2.2 | Manage OpenBao/Vault resources |
| upbound-provider-keycloak | v1.1.0 | Manage Keycloak resources |
| upbound-provider-digitalocean | v0.3.0 | Manage DigitalOcean resources |
| upbound-provider-kubernetes | v0.10.0 | Manage Kubernetes clusters |
| upbound-provider-helm | v0.15.0 | Manage Helm releases |

## Functions

### Function (pkg.crossplane.io/v1alpha1)

Installs a Crossplane function for composition logic and validation.

```yaml
apiVersion: pkg.crossplane.io/v1alpha1
kind: Function
metadata:
  name: function-kcl
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-kcl:v0.4.0
```

**Key Fields**:
- `metadata.name`: Function name for use in compositions
- `spec.package`: Package URL with version tag

### Installed Functions

| Name | Version | Purpose |
|------|---------|---------|
| function-kcl | v0.4.0 | Composition logic in KCL |
| function-auto-ready | v0.2.0 | Automatic readiness status management |

## Checking Installation

### List Providers

```bash
kubectl get providers.crossplane.io
```

Output:
```
NAME                              TRAFFIC   HEALTHY   AGE
upbound-provider-keycloak         Active    Healthy   10d
upbound-provider-vault            Active    Healthy   10d
upbound-provider-digitalocean     Active    Healthy   10d
upbound-provider-kubernetes       Active    Healthy   10d
upbound-provider-helm             Active    Healthy   10d
```

### List Functions

```bash
kubectl get functions.crossplane.io
```

Output:
```
NAME                           TRAFFIC   HEALTHY   AGE
function-auto-ready            Active    Healthy   10d
function-kcl                   Active    Healthy   10d
```

## Troubleshooting

### Provider Not Healthy

**Symptom**: `HEALTHY` column shows `Unhealthy`

**Possible Causes**:
- Package can't be downloaded (network issue)
- Package version doesn't exist
- Pod resource limits exceeded

**Solutions**:
1. Check package URL is correct
2. Check network connectivity to package repository
3. Check provider pod logs: `kubectl logs -n crossplane-system -l pkg.crossplane.io/provider`
4. Review package version compatibility

### Provider Version Updates

To update a provider:

1. Edit the version in `crossplane/init/providers/<provider>.yaml`
2. Apply the change: `kubectl apply -f crossplane/init/providers/<provider>.yaml`
3. Wait for new version to become healthy before using

**Note**: Always test provider updates in non-production environments first.

### Resource Limits

Provider pods default to resource limits. If you see OOMKilled errors, increase limits in the provider installation:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-vault
spec:
  package: xpkg.upbound.io/upbound/provider-vault:v2.2.2
  controllerConfigRef:
    name: vault-config
```

```yaml
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: vault-config
spec:
  podSecurityContext:
    fsGroup: 2000
  serviceAccountName: upbound-provider-vault
  containerSecurityContext:
    allowPrivilegeEscalation: false
  resources:
    limits:
      cpu: "1"
      memory: 512Mi
    requests:
      cpu: "100m"
      memory: 128Mi
```
