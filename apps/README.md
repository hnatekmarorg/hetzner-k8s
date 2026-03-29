# Production Cluster - DOKS with GPU Support

This directory contains ArgoCD Applications for managing production DigitalOcean Kubernetes clusters with GPU support.

## Overview

The production cluster is configured with:
- **Primary CPU Node Pool**: 1 static node (s-4vcpu-16gb) for general workloads
- **GPU Node Pool NVIDIA Labelfire**: Autoscaling L40S 48GB nodes (0-5) for AI/ML workloads

## Architecture

```
prod-cluster
├── cpu-workers (static)
│   └── s-4vcpu-16gb - 1 node
│   └── General workloads, system services
│
└── gpu-workers (autoscaling)
    └── gpu-l40sx1-48gb - 0-5 nodes
    └── AI/ML workloads (marked with nvidia.com/gpu resource requests)
```

## Node Pool Details

### CPU Node Pool (Static)
- **Name**: `cpu-workers`
- **Size**: `s-4vcpu-16gb`
- **Node Count**: 1 (fixed)
- **Use Case**: System services, general workloads, deployments without GPU requirements

### GPU Node Pool (Autoscaling)
- **Name**: `gpu-workers`
- **Size**: `gpu-l40sx1-48gb` (NVIDIA L40S 48GB)
- **Node Count**: 0 (initially) - Autoscales 0-5 nodes
- **Autoscaling**: Enabled
  - **Min Nodes**: 0 (scale to zero when idle)
  - **Max Nodes**: 5
- **Labels**:
  - `nvidia.com/gpu: true`
  - `workload-type: ai-ml`
  - `node-class: gpu`
- **Taints**:
  - `nvidia.com/gpu=true:NoSchedule` - Ensures only GPU pods schedule here
  - `workload-type=ai-ml:NoSchedule` - Additional isolation

## Deploying

1. **Ensure ArgoCD is installed** and accessible in your cluster

2. **Apply the Application**:
   ```bash
   kubectl apply -f apps/doks/clusters/prod.yaml -n argocd
   ```

3. **Monitor the deployment**:
   ```bash
   # Check application status
   argocd app get prod-cluster

   # Watch sync progress
   argocd app sync prod-cluster --watch
   ```

## Scheduling Workloads

### For GPU Workloads

Pods requiring GPU resources must include:
- GPU resource request
- Tolerations for GPU node taints

Example:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-workload
spec:
  nodeSelector:
    node-class: gpu
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
    - key: workload-type
      operator: Equal
      value: ai-ml
      effect: NoSchedule
  containers:
    - name: ai-app
      image: your-ml-app:latest
      resources:
        requests:
          nvidia.com/gpu: 1
        limits:
          nvidia.com/gpu: 1
```

### For CPU Workloads

Pods without GPU requests will schedule on CPU nodes:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cpu-workload
spec:
  containers:
    - name: app
      image: your-app:latest
      resources:
        requests:
          memory: "1Gi"
          cpu: "500m"
        limits:
          memory: "2Gi"
          cpu: "1"
```

## Available GPU Options

The chart supports all DigitalOcean GPU droplet sizes. Change `size:` in `values-prod.yaml`:

### AMD GPUs
| GPU | Slug | Memory |
|-----|------|--------|
| MI300X | `gpu-mi300x1-192gb` | 192GB |
| MI300X (8x) | `gpu-mi300x8-1536gb` | 1536GB |

### NVIDIA GPUs
| GPU | Slug | Memory |
|-----|------|--------|
| H100 | `gpu-h100x1-80gb` | 80GB |
| H100 (8x) | `gpu-h100x8-640gb` | 640GB |
| L40S | `gpu-l40sx1-48gb` | 48GB |
| RTX 4000 | `gpu-4000adax1-20gb` | 20GB |
| RTX 6000 | `gpu-6000adax1-48gb` | 48GB |

## Monitoring

After deployment, check node pools:

```bash
# List all nodes
kubectl get nodes

# List nodes with GPU labels
kubectl get nodes -l nvidia.com/gpu=true

# Check GPU resources
kubectl describe node <gpu-node-name>

# Verify GPU device plugin
kubectl get pods -n kube-system | grep nvidia
```

## Autoscaling

The GPU node pool automatically scales:
- **Scale Up**: When pods tolerate GPU taints and request GPU resources
- **Scale Down**: When no GPU pods are running (after cooldown period)

Test autoscaling:
```bash
# Deploy a GPU pod
kubectl apply -f examples/gpu-workload.yaml

# Scale to zero when done
kubectl delete all --all -l workload-type=ai-ml
```

## Troubleshooting

### GPU Nodes Not Scaling Up
- Ensure pods have GPU resource requests and tolerations
- Check `kubectl describe node pool` in Crossplane resources
- Verify taint configuration matches pod tolerations

### App Not Syncing
```bash
 argocd app get prod-cluster --refresh
 argocd app logs -f prod-cluster
```

### GPU Issues on Nodes
```bash
# Check nvidia-device-plugin
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds

# Test GPU on a node
kubectl run -it --rm --restart=Never --image=nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-smi -- nvidia-smi
```

## Cost Optimization

1. **GPU Autoscaling**: Successfully configured with scale-to-zero
2. **Node Affinity**: Use node selectors to prevent unneeded GPU consumption
3. **Resource Limits**: Set appropriate GPU limits on pods
4. **Vertical Pod Autoscaler**: Consider for non-GPU workloads on CPU nodes

## Configuration Files

- **`apps/doks/clusters/prod.yaml`**: ArgoCD Application manifest
- **`charts/doks-cluster/values-prod.yaml`**: Production Helm values
- **`charts/doks-cluster/templates/cluster.yaml`**: Multi-nodepool support (updated)

## Next Steps

After deployment:
1. Configure monitoring (Prometheus, Grafana) for GPU metrics
2. Set up GPU resource quotas if needed
3. Configure PersistentVolumes for ML model storage
4. Install NVIDIA DCGM Exporter for detailed GPU telemetry
