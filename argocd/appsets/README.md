# ArgoCD ApplicationSets

ApplicationSets enable multi-cluster and multi-environment deployments using a template pattern. This is the recommended approach (over individual Application manifests) when:

- Managing the same app across multiple environments (dev/staging/prod)
- Deploying to multiple clusters
- Generating applications from a directory structure

## Cluster Resources ApplicationSet

The following ApplicationSet generates Applications for DOKS (DigitalOcean Kubernetes) clusters. Each cluster directory under [`charts/doks-cluster`](../../charts/doks-cluster) is automatically wired up.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: doks-clusters
  namespace: argocd
spec:
  goTemplate: true
  # Sync policy: applications are created and managed by this set
  syncPolicy:
    preserveResourcesOnDeletion: false
  generators:
    # Git generator: scan charts/doks-cluster for cluster configs
    - git:
        repoURL: https://github.com/hnatekmarorg/hetzner-k8s.git
        revision: HEAD
        directories:
          - path: charts/doks-cluster/values-*.yaml
  template:
    metadata:
      name: 'doks-cluster-{{ index (regexFind "values-(.+)\\.yaml" .path.filename) 1 }}'
      annotations:
        argocd.argoproj.io/sync-wave: "4"
    spec:
      project: default
      source:
        repoURL: https://github.com/hnatekmarorg/hetzner-k8s.git
        targetRevision: HEAD
        path: charts/doks-cluster
        helm:
          releaseName: 'doks-cluster-{{ index (regexFind "values-(.+)\\.yaml" .path.filename) 1 }}'
          valueFiles:
            - '{{ .path.filename }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'doks-cluster-{{ index (regexFind "values-(.+)\\.yaml" .path.filename) 1 }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

This replaces the manually commented-out Application in `argocd/manifests/digitalocean/production.yaml`.

## Usage

1. Create a new values file: `charts/doks-cluster/values-staging.yaml`
2. The Git generator automatically discovers it and creates an Application
3. ArgoCD syncs the new cluster

## Benefits over Individual Applications

- **Self-service**: Add a values file → new cluster provisioned
- **Consistent**: Template ensures all clusters have identical configuration
- **No boilerplate**: Single YAML file replaces N Application manifests
- **Scalable**: Add 10 clusters with one file instead of 10 files
