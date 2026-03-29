# 🚀 Quick Start: Deploy Production GPU Cluster

## Overview

Deploy a production-ready DigitalOcean Kubernetes cluster with:
- ✅ 1 static CPU node (s-4vcpu-16gb)
- ✅ Autoscaling GPU nodes (L40S 48GB, 0-5 nodes)
- ✅ Cost optimization (scale-to-zero)
- ✅ Proper node isolation

## 1️⃣ Deploy the Cluster

```bash
kubectl apply -f apps/doks/clusters/prod.yaml -n argocd
```

## 2️⃣ Monitor Deployment

```bash
# Check status
argocd app get prod-cluster

# Watch sync progress
argocd app sync prod-cluster --watch
```

Wait ~10-15 minutes for DigitalOcean to provision the cluster.

## 3️⃣ Verify GPU Setup

```bash
# Apply a test GPU workload (triggers scale-up)
kubectl apply -f apps/examples/gpu-workload.yaml

# Wait for GPU node to be provisioned (2-5 minutes)
kubectl get nodes -w

# Verify GPU is available
kubectl run -it --rm --restart=Never \
  --image=nvidia/cuda:12.2.0-base-ubuntu22.04 nvidia-check \
  -- nvidia-smi

# Clean up test workload (triggers scale-down)
kubectl delete -f apps/examples/gpu-workload.yaml
```

## 📊 What's Happening

1. **ArgoCD** applies the application manifest
2. **Crossplane** provisions a DigitalOcean Kubernetes cluster
3. **CPU node** (s-4vcpu-16gb) is created immediately
4. **GPU node** is created only when GPU workload is deployed
5. **GPU node** is automatically deleted after 10-15 minutes idle

## 🎯 Next Steps

- [ ] Read [DEPLOY.md](DEPLOY.md) for detailed instructions
- [ ] Read [README.md](README.md) for architecture details
- [ ] Update the domain in `charts/doks-cluster/values-prod.yaml`
- [ ] Configure SSL/TLS for ArgoCD ingress
- [ ] Set up monitoring (Prometheus, Grafana)

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [DEPLOY.md](DEPLOY.md) | Step-by-step deployment guide |
| [README.md](README.md) | Architecture and reference |
| [doks/clusters/README.md](doks/clusters/README.md) | Cluster management |

## 🔧 Troubleshooting

```bash
# Check application status
argocd app get prod-cluster --refresh

# View application logs
argocd app logs -f prod-cluster

# Check Crossplane resources
kubectl get cluster -n crossplane-system
kubectl describe cluster prod-cluster -n crossplane-system

# List all nodes
kubectl get nodes

# Monitor GPU node provisioning
watch kubectl get nodes -l nvidia.com/gpu=true
```

## 💡 Tips

- **Cost**: GPU nodes scale to zero automatically when idle
- **Monitoring**: Check ArgoCD UI for real-time sync status
- **Scaling**: Apply multiple GPU pods to add more nodes (up to max 5)
- **Deletion**: Delete the application to remove everything

## 🎉 Success!

Your production GPU cluster is ready for AI/ML workloads!
