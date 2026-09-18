# Hetzner Kubernetes GitOps Repository

This repository manages Kubernetes infrastructure on Hetzner Cloud using GitOps principles.

## Technologies

- **ArgoCD**: GitOps controller for application deployment
- **Crossplane**: Cloud resource provisioning (OpenBao/Vault, Keycloak, DigitalOcean)
- **Helm Charts**: Package management for Kubernetes applications
- **Kubernetes**: Container orchestration on Hetzner Cloud

## Documentation

- [AGENTS.md](AGENTS.md) - Guidelines for AI coding agents
- [docs/](docs/) - Detailed documentation for workflows and configurations

## OpenBao Login Roles

You can authenticate to OpenBao (Vault) at `https://bao.hnatekmar.xyz` using OIDC/SSO through Keycloak.

### Available Roles

| Role Name | Required Keycloak Group | Token TTL | Policies Assigned |
|-----------|------------------------|-----------|-------------------|
| `admin` | `admin` | 24 hours | `admin-identity` |
| `algovectra` | `algovectra` | 1-4 hours | `algovectra`, `algovectra-ssh` |
| `hnatekmarorg` | `hnatekmarorg-base` | 1-4 hours | `hnatekmarorg` |

### Role Permissions

| Role | Path | Capabilities | Description |
|------|------|--------------|-------------|
| `admin` | `*` | All (create, read, update, patch, delete, list, scan) | Full access to all OpenBao paths |
| `algovectra` | `algovectra/data/*` | All CRUD + list, scan | Read/write access to Algovectra secrets data |
| `algovectra` | `algovectra/metadata/*` | All CRUD + list, scan | Read/write access to Algovectra secrets metadata |
| `algovectra` | `algovectra-ssh/*` | read, list, create, update | Manage Algovectra SSH secrets engine |
| `algovectra` | `algovectra-ssh/sign/*` | create, update | Sign SSH certificates for Algovectra |
| `hnatekmarorg` | `hnatekmarorg-ssh/sign/user` | create, update | Sign user SSH certificates |

### Policy Details

<details>
<summary><strong>admin-identity</strong> - Full administrative access</summary>

```hcl
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "scan"]
}
```
</details>

<details>
<summary><strong>algovectra</strong> - Algovectra secrets management</summary>

```hcl
path "algovectra/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "scan"]
}
path "algovectra/metadata/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "scan"]
}
```
</details>

<details>
<summary><strong>algovectra-ssh</strong> - Algovectra SSH certificate signing</summary>

```hcl
path "algovectra-ssh/*" {
  capabilities = ["read", "list", "create", "update"]
}
path "algovectra-ssh/sign/*" {
  capabilities = ["create", "update"]
}
```
</details>

<details>
<summary><strong>hnatekmarorg</strong> - hnatekmarorg SSH certificate signing</summary>

```hcl
path "hnatekmarorg-ssh/sign/user" {
  capabilities = ["create", "update"]
}
```
</details>

### How to Login

```bash
# Login with a specific role
bao login -method=oidc role=<role-name>

# Examples:
bao login -method=oidc role=hnatekmarorg
bao login -method=oidc role=algovectra
bao login -method=oidc role=admin
```

### Requirements

1. Be a member of the corresponding Keycloak group in `https://sso.hnatekmar.xyz`
2. Have the `bao` CLI installed (or use `vault` command)
3. Access to the Kubernetes cluster

## SSH Certificate Classes (`infra` / `dev`)

SSH access is split by **class**, the same way Kubernetes cluster access is: two SSH CAs,
one per population of machines. An infra host trusts only the infra CA, a dev host only the
dev CA, so a certificate from the other class does not verify there at all.

| Class | Hosts | CA mount | Signing path | Policies |
|-------|-------|----------|--------------|----------|
| `infra` | balteus, TrueNAS, GitHub runner, keepers | `hnatekmarorg-ssh-infra` | `hnatekmarorg-ssh-infra/sign/admin` | `hnatekmarorg-ssh-class-infra` |
| `dev` | sandboxes — `kubernetes-sandbox` (VM 133) | `hnatekmarorg-ssh-dev` | `hnatekmarorg-ssh-dev/sign/admin` | `hnatekmarorg-ssh-class-dev` |

The certificate's principal is the *tier* (`admin`), not the class — the class is the CA
that signed it. Hosts install the class public key as `TrustedUserCAKeys` plus an
`AuthorizedPrincipalsFile` listing `admin`; both classes' certificates are otherwise
identical in shape.

```bash
# on a host (root): install the class trust anchor + sshd certificate-auth config
scripts/ssh-ca/enroll.sh --class infra trust
scripts/ssh-ca/enroll.sh --class infra verify

# on any machine, container included (no root, no OpenBao CLI): this machine's certificate
scripts/ssh-ca/enroll.sh dev              # == scripts/ssh-ca/enroll.sh dev issue
scripts/ssh-ca/enroll.sh dev --ttl 168h   # for an image that is built once
```

`enroll.sh` needs only bash, ssh-keygen and curl/wget, and reads the token from
`BAO_TOKEN`, `--token` or `~/.vault-token`. It is installable by hash:

```Dockerfile
RUN curl -fsSLo /tmp/enroll.sh        "$RAW/scripts/ssh-ca/enroll.sh"        && \
    curl -fsSLo /tmp/enroll.sh.sha256 "$RAW/scripts/ssh-ca/enroll.sh.sha256" && \
    (cd /tmp && sha256sum -c enroll.sh.sha256)                               && \
    bash /tmp/enroll.sh dev --ttl 168h
```

| Policy | Path | Capabilities | Description |
|--------|------|--------------|-------------|
| `hnatekmarorg-ssh-class-infra` | `hnatekmarorg-ssh-infra/sign/admin` | create, update | Sign infra-class admin certificates |
| `hnatekmarorg-ssh-class-infra` | `hnatekmarorg-ssh-infra/config/ca` | read | Read the infra CA public key (trust anchor) |
| `hnatekmarorg-ssh-class-dev` | `hnatekmarorg-ssh-dev/sign/admin` | create, update | Sign dev-class admin certificates |
| `hnatekmarorg-ssh-class-dev` | `hnatekmarorg-ssh-dev/config/ca` | read | Read the dev CA public key (trust anchor) |

Full design, the verified contract, problems found in the existing roles, and the rollout
plan: **[docs/crossplane/ssh-ca-classes.md](docs/crossplane/ssh-ca-classes.md)**.

## OpenBao Recovery - Required Secrets

After reinitializing OpenBao, the following secrets must be manually created to restore cluster functionality:

### Prerequisites

```bash
# Set up environment
export BAO_ADDR=https://bao.hnatekmar.xyz
export BAO_TOKEN=<root-token>
```

### Required Secrets

1. **Keycloak Admin Credentials** (clusters path)
   ```bash
   bao kv put clusters/admin/keycloak username=keycloak password=<random-password>
   ```

2. **Keycloak Database Credentials** (clusters path)
   ```bash
   # This will be auto-generated by ExternalSecrets generator
   # Or manually create:
   bao kv put clusters/keycloak/db password=<random-password> username=keycloak
   ```

3. **DigitalOcean API Token** (clusters path)
   ```bash
   bao kv put clusters/digitalocean token=<digitalocean-api-token>
   ```

4. **GitHub Algovectra Token** (algovectra path)
   ```bash
   bao kv put algovectra/github token=<github-personal-access-token>
   ```

5. **GitHub hnatekmarorg Token** (devops path)
   ```bash
   bao kv put devops/github token=<github-personal-access-token>
   ```

### Optional Secrets

6. **SSO / OIDC client secret** — provisioned by the Keycloak client resource (`crossplane/config/keycloak/clients/bao-client.yaml`), not a KV secret. The `sso/keycloak/client-secret` KV path no longer exists.

### Verification

After creating the secrets, verify they're syncing to Kubernetes:

```bash
# Check ExternalSecrets
kubectl get externalsecret -A

# Check synced secrets
kubectl get secret -n keycloak | grep keycloak
kubectl get secret -n crossplane-system | grep -E 'digitalocean|github'

# Check ArgoCD application status
kubectl get application crossplane-secrets -n argocd
```

### Quick Recovery Script

A recovery script is provided at `scripts/recover-bao-secrets.sh`:

```bash
# Make it executable
chmod +x scripts/recover-bao-secrets.sh

# Set your root token
export BAO_TOKEN=s.<your-root-token>

# Run the script
./scripts/recover-bao-secrets.sh
```

The script will:
- Check for existing secrets
- Prompt for required tokens
- Create missing secrets with random passwords where appropriate
- Verify synchronization status

Or run manually:
```bash
# Quick script to restore essential secrets after OpenBao reinit

# Set variables
BAO_ADDR=https://bao.hnatekmar.xyz
BAO_TOKEN=<root-token>

# Create required secrets
bao kv put clusters/admin/keycloak username=keycloak password=$(openssl rand -base64 32 | tr -d '/+')
bao kv put clusters/digitalocean token=<digitalocean-api-token>
bao kv put algovectra/github token=<github-algovectra-token>
bao kv put devops/github token=<github-hnatekmarorg-token>

# Verify
sleep 10
kubectl get externalsecret -A | grep -v "False\|Error"
echo "\nCheck ArgoCD: kubectl get application crossplane-secrets -n argocd"
```

### Troubleshooting

If secrets are not syncing:

1. Check ClusterSecretStore status:
   ```bash
   kubectl get clustersecretstore local -o yaml | grep -A5 'conditions:'
   ```

2. Check ExternalSecret errors:
   ```bash
   kubectl get externalsecret -A -o wide
   kubectl logs -n external-secrets deployment/external-secrets --tail=50
   ```

3. Restart External Secrets controller:
   ```bash
   kubectl rollout restart deployment external-secrets -n external-secrets
   ```

### Related Documentation

- [OpenBao Configuration Guide](docs/crossplane/openbao.md)
- [Keycloak Configuration Guide](docs/crossplane/keycloak.md)
- [SSO Overview](docs/crossplane/sso-overview.md) - Cross-service SSO reference (OpenBao, ArgoCD, Keycloak)
- [SSO Integration Guide](docs/crossplane/sso-integration.md)
- [External Secrets Configuration](docs/crossplane/external-secrets.md)
- [Monitoring Stack](docs/monitoring.md) - Prometheus, Grafana, and Loki setup

## Quick Start

```bash
# Load environment variables
direnv allow

# Verify kubectl access
kubectl cluster-info

# Check ArgoCD applications
kubectl get app -n argocd
```

## Directory Structure

```
.
├── argocd/              # ArgoCD Application definitions
├── charts/              # Custom Helm charts
├── crossplane/          # Crossplane resources
├── docs/                # Documentation
└── scripts/             # Utility scripts
```
