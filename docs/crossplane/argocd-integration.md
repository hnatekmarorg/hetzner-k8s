# Configuring Crossplane with ArgoCD

This document describes the required ArgoCD configuration for proper Crossplane resource management. Based on the [official Crossplane documentation](https://docs.crossplane.io/latest/guides/crossplane-with-argo-cd/).

## Required ArgoCD Configuration

The following configuration must be applied to the `argocd-cm` ConfigMap in the `argocd` namespace:

### 1. Resource Tracking Method

Crossplane resources use server-side apply. Set annotation-based tracking to avoid conflicts:

```yaml
# argocd-cm ConfigMap
data:
  application.resourceTrackingMethod: annotation
```

### 2. Health Checks

Add custom health checks for Crossplane resource kinds so ArgoCD can properly report their status:

```yaml
resource.customizations: |
  "*.crossplane.io/*":
    health.lua: |
      health_status = {}
      if obj.status ~= nil then
        if obj.status.conditions ~= nil then
          for i, condition in ipairs(obj.status.conditions) do
            if condition.type == "Synced" and condition.status == "True" then
              health_status.status = "Healthy"
              health_status.message = "Resource synced"
              return health_status
            end
            if condition.type == "Synced" and condition.status == "False" then
              health_status.status = "Degraded"
              health_status.message = condition.message
              return health_status
            end
          end
        end
      end
      health_status.status = "Progressing"
      health_status.message = "Waiting for resource to be synced"
      return health_status

  "*.upbound.io/*":
    health.lua: |
      health_status = {}
      if obj.status ~= nil then
        if obj.status.conditions ~= nil then
          for i, condition in ipairs(obj.status.conditions) do
            if condition.type == "Synced" and condition.status == "True" then
              health_status.status = "Healthy"
              health_status.message = "Resource synced"
              return health_status
            end
            if condition.type == "Synced" and condition.status == "False" then
              health_status.status = "Degraded"
              health_status.message = condition.message
              return health_status
            end
          end
        end
      end
      health_status.status = "Progressing"
      health_status.message = "Waiting for resource to be synced"
      return health_status
```

### 3. Resource Exclusions

Exclude high-churn resources from the ArgoCD UI to reduce noise:

```yaml
resource.exclusions: |
  - apiGroups:
    - "*"
    kinds:
    - ProviderConfigUsage
```

### 4. QPS Tuning

Crossplane introduces many CRDs which can overwhelm the default ArgoCD client. Set the ArgoCD application controller's QPS:

```yaml
# argocd-cm ConfigMap or environment variable on argocd-application-controller
data:
  # Or set as env var on the controller deployment:
  # ARGOCD_K8S_CLIENT_QPS=300
```

## Applying the Configuration

If the `argocd-cm` ConfigMap is managed by ArgoCD itself (via the `argocd` Application), add the above entries to the Helm chart values in [`argocd/apps/platform/argocd.yaml`](../../argocd/apps/platform/argocd.yaml).

If it is managed outside of ArgoCD (e.g., manually or via a bootstrap script), apply directly:

```bash
kubectl patch configmap argocd-cm -n argocd --type=merge -p '{
  "data": {
    "application.resourceTrackingMethod": "annotation",
    "resource.customizations": "...",
    "resource.exclusions": "..."
  }
}'
```

## Verifying

After applying, check that Crossplane resources show proper health status in ArgoCD:

```bash
kubectl get app -n argocd -o wide | grep crossplane
```

Each Crossplane Application should show `Healthy` status once its resources are synced.
