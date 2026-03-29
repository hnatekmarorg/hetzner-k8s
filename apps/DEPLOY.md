# Quick Deployment Guide - Production GPU Cluster

## What Was Created

1. **`apps/doks/clusters/prod.yaml`** - ArgoCD Application for production cluster with:
   - 1 static CPU node (s-4vcpu-16gb)
   - Autoscaling GPU node pool (L40S 48GB, 0-5 nodes)

2. **`charts/doks-cluster/values-prod.yaml`** - Production configuration
   - GPU autoscaling enabled (0-5 nodes)
   - Proper node labels and taints
   - Production-ready ArgoCD values

3. **`charts/doks-cluster/templates/cluster.yaml`** - Updated to support multiple node pools

4. **`apps/examples/gpu-workload.yaml`** - Simple GPU test pod
5. **`apps/examples/ml-training-job.yaml`** - Realistic ML training job example

## Deploy the Production Cluster

```bash
# 1. Apply the ArgoCD Application
kubectl apply -f apps/doks/clusters/prod.yaml -n argocd

# 2. Wait for sync and cluster provisioning
argocd app get prod-cluster
argocd app sync prod-cluster --watch
```

Expected time: ~10-15 minutes for DigitalOcean cluster creation.

## Verify Deployment

```bash
# Check Crossplane resources
kubectl get cluster -n crossplane-system
kubectl get release -n crossplane-system

# List nodes (after cluster is ready)
kubectl get nodes

# Check for GPU nodes
kubectl get nodes -l nvidia.com/gpu=true
```

## Test GPU Autoscaling

### Step 1: Apply a GPU workload (triggers scale-up)

```bash
kubectl apply -f apps/examples/gpu-workload.yaml
```

This will:
1. Create a GPU pod with tolerations for GPU node taints
2. Autoscaler will provision an L40S GPU node
3. Pod will run on the new GPU node

### Step 2: Wait for GPU node to be ready

```bash
# Watch node provisioning
kubectl get nodes -w

# Once ready, check GPU on the node
kubectl run -it --rm --restart=Never \
  --image=nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-check \
  -- nvidia-smi
```

### Step 3: Verify GPU workload ran

```bash
# Check pod logs
kubectl logs gpu-test-pod

# Delete the workload
kubectl delete -f apps/examples/gpu-workload.yaml
```

### Step 4: Test scale-to-zero

```bash
# After some minutes (usually 10-15), GPU node will be removed
watch kubectl get nodes -l nvidia.com/gpu=true
```

The GPU node pool should scale back to 0 when no GPU pods are running.

## Deploy a Real ML Workload

```bash
kubectl apply -f apps/examples/ml-training-job.yaml

# Watch the job
kubectl get jobs -w

# View logs
kubectl logs -f job/ml-training-job

# Cleanup when done
kubectl delete -f apps/examples/ml-training-job.yaml
```

## Monitor from ArgoCD

```bash
# Open ArgoCD UI (update URL as needed)
open https://argocd.yourdomain.com

# Or use CLI
argocd app get prod-cluster --refresh
argocd app tree prod-cluster
```

## Cluster Access

After the cluster is ready, get the kubeconfig:

```bash
# The cluster connection secret is in crossplane-system
kubectl get secret prod-cluster -n crossplane-system -o yaml

# Or use doctl (if configured)
doctl kubernetes cluster list
doctl kubernetes cluster kubeconfig save prod-cluster
```

## Customization

### Change GPU Type

Edit `charts/doks-cluster/values-prod.yaml`:

```yaml
additionalNodePools:
  - name: "gpu-workers"
    size: "gpu-h100x1-80gb"  # Change to H100, MI300X, etc.
```

Then sync ArgoCD:
```bash
argocd app sync prod-cluster
```

### Adjust Autoscaling Limits

Edit `values-prod.yaml`:

```yaml
additionalNodePools:
  - name: "gpu-workers"
    minNodes: 2   # Keep 2 GPUs minimum
    maxNodes: 10  # Scale up to 10 GPUs
```

### Add More Node Pools

Add to `additionalNodePools` in `values-prod.yaml`:

```yaml
additionalNodePools:
  - name: "gpu-workers-l40s"
    size: "gpu-l40sx1-48gb"
    nodeCount: 0
    autoScale: true
    minNodes: 0
    maxNodes: 5

  - name: "high-cpu-workers"
    size: "c-32"
    nodeCount: 2
    autoScale: false
```

## Troubleshooting

### Cluster Not Syncing

```bash
argocd app get prod-cluster --refresh
argocd app logs -f prod-cluster

# Check Crossplane provider status
kubectl get providerconfig
kubectl get providers
```

### GPU Pods Pending

```bash
# Check scheduling events
kubectl describe pod <gpu-pod-name> | grep -A 10 Events

# Verify node taints
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# Check pod tolerations
kubectl get pod <gpu-pod-name> -o jsonpath='{.spec.tolerations}' | jq
```

### GPU Node Not Provisioning

```bash
# Check DigitalOcean status
kubectl get cluster prod-cluster -n crossplane-system -o yaml

# View events
kubectl get events --sort-by='.lastTimestamp' | grep -i error
```

## Production Checklist

- [ ] Update the domain in `values-prod.yaml` (argocd.yourdomain.com)
- [ ] Configure SSL/TLS for ArgoCD ingress (cert-manager)
- [ ] Set up monitoring (Prometheus, Grafana)
- [ ] Configure GPU metrics (NVIDIA DCGM Exporter)
- [ ] Set up backup for ML artifacts
- [ ] Configure resource quotas
- [ ] Enable PodDisruptionBudgets for production workloads
- [ ] Review and adjust autoscaling parameters

## Cost Optimization Tips

1. **Scale-to-zero is enabled** - GPU nodes automatically scale down when idle
2. **Use node selectors** - Prevent CPU workloads from scheduling on GPU nodes
3. **Set appropriate limits** - Don't request more GPU than you need
4. **Use Spot/Preemptible** (if available) - Test workloads first
5. **Monitor usage** - Set up alerts for idle GPU clusters

## Support & Resources

- [ArgoCD Docs](https://argo-cd.readthedocs.io/)
- [DigitalOcean GPU Nodes](https://docs.digitalocean.com/products/kubernetes/details/supported-gpus/)
- [Crossplane DigitalOcean Provider](https://github.com/crossplane-contrib/provider-upjet-digitalocean)
- [NVIDIA Kubernetes Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
