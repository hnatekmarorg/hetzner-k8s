# DOKS Cluster Applications

This directory contains ArgoCD Application manifests for managing DigitalOcean Kubernetes clusters.

## Structure

Each cluster is defined as a separate YAML file:
- `<name>.yaml` - ArgoCD Application for that specific cluster

## Available Clusters

### Production (prod.yaml)

**Configuration:**
- **Region**: nyc1
- **CPU Nodes**: 1x s-4vcpu-16gb (static)
- **GPU Nodes**: Autoscaling L40S 48GB (0-5 nodes)

**Deploy:**
```bash
kubectl apply -f prod.yaml -n argocd
```

**Monitor:**
```bash
argocd app get prod-cluster
argocd app sync prod-cluster --watch
```

## Adding a New Cluster

1. **Copy the production template:**
   ```bash
   cp prod.yaml <your-cluster-name>.yaml
   ```

2. **Edit the file with your configuration:**
   - Update `metadata.name` to match your cluster name
   - Update `spec.source.helm.values` with your specific settings
   - Update health check names to match your cluster

3. **Deploy the new cluster:**
   ```bash
   kubectl apply -f <your-cluster-name>.yaml -n argocd
   ```

## Example Configuration

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-cluster
  namespace: argocd
  labels:
    environment: production
    purpose:eks-cluster
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  source:
    repoURL: https://github.com/hnatekmar/hetzner-k8s.git
    targetRevision: HEAD
    path: charts/doks-cluster
    helm:
      valueFiles:
        - values-prod.yaml
      values: |
        cluster:
          name: my-cluster
          region: nyc1
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
  health:
    resources:
      - kind: Cluster
        apiVersion: kubernetes.digitalocean.crossplane.io/v1alpha1
        name: my-cluster
        namespace: crossplane-system
      - kind: Release
        apiVersion: helm.crossplane.io/v1beta1
        name: my-cluster-argocd
        namespace: crossplane-system
```

## Environment-Specific Clusters

For different environments (dev, staging, prod), you can create:
- `dev.yaml`
- `staging.yaml`
- `prod.yaml`

Each can point to different values files:
- `values-dev.yaml`
- `values-staging.yaml`
- `values-prod.yaml`

## Best Practices

1. **Naming Convention**: Use environments as prefixes (`dev-ml`, `prod-inference`, etc.)
2. **Value Files**: Create per-environment value files in `charts/doks-cluster/`
3. **Selective Sync**: Use ArgoCD project/label selectors for environment separation
4. **Resource Labels**: Add environment labels for better organization

## Management Commands

```bash
# List all DOKS cluster apps
argocd app list | grep doks

# Sync all DOKS clusters
for app in $(argocd app list | grep doks | awk '{print $1}'); do
  argocd app sync $app
done

# Check health of all clusters
argocd app list -l purpose=eks-cluster | awk '{print $1}' | \
  xargs -I {} argocd app get {} --output json | jq -r '.status.health.status'
```

## Troubleshooting

### Application Not Syncing
```bash
argocd app get <cluster-name> --refresh
argocd app logs -f <cluster-name>
```

### Crossplane Resources Not Created
```bash
kubectl get cluster -n crossplane-system
kubectl describe cluster <cluster-name> -n crossplane-system
```

### Connection Issues
```bash
# Check provider configs
kubectl get providerconfig
kubectl describe providerconfig digitalocean
```

## See Also

- [Main README](../README.md) - Detailed documentation on cluster architecture
- [DEPLOY Guide](../DEPLOY.md) - Step-by-step deployment instructions
- [GPU Workloads](../examples/) - Example workloads for GPU clusters
