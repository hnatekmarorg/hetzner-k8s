# Coder workspace templates

Terraform templates for [Coder v2](https://coder.com) workspaces. This repo is
the source of truth; templates are **pushed** to the running Coder instance
(Coder v2 OSS does not git-sync templates — the `.tf` lives in Coder's Postgres
once registered).

## Why no extra cluster setup

The Coder Helm chart creates a service account (`coder`) with RBAC to manage
pods, PVCs and deployments in the `coder` namespace (`workspacePerms=true`,
`enableDeployments=true`). The starter template uses the **in-cluster**
Kubernetes provider (`use_kubeconfig=false`), so it provisions workspaces on the
**same cluster** Coder runs on, using that service account. No kubeconfig, no
manual RBAC, no second cluster.

## `kubernetes/`

A basic Ubuntu workspace (code-server) with a per-workspace home PVC on the
cluster's `local-path` StorageClass. Parameters: CPU (2/4/6), memory (2/4/8 GB),
home disk (1–50 GB).

### Register / update

After Coder is up (https://coder-hetzner.hnatekmar.xyz), log in via SSO and
create an API token, then:

```bash
# one-time setup of the CLI (if not installed)
#   curl -L https://coder.com/install.sh | sh
export CODER_URL=https://coder-hetzner.hnatekmar.xyz
export CODER_SESSION_TOKEN=<your token from the dashboard>

cd coder-templates/kubernetes
coder templates push -d . kubernetes --variable namespace=coder
```

Re-run the same `push` command to update the template after editing `main.tf`.

### Create a workspace

```bash
coder create -t kubernetes my-dev
coder config-ssh   # optional: ssh into the workspace
```

### Notes

- Workspaces land in the `coder` namespace. To use a dedicated workspace
  namespace instead, create it and grant the Coder SA there
  (`coder.serviceAccount.workspaceNames` in the Helm values), then push the
  template with `--variable namespace=<that-ns>`.
- PVCs use `wait_until_bound=false` + `local-path`; on a single-node cluster
  they bind immediately. For multi-node, prefer a shared StorageClass
  (e.g. democratic-csi / the 10G NAS) for portable home dirs.
- The base image is `codercom/example-base:ubuntu`; swap for your own
  (`devcontainer`, CUDA image, etc.) in the template.
