# Coder (self-hosted v2)

Self-hosted [Coder v2](https://github.com/coder/coder) for developer and agent
workspaces, deployed on the Hetzner cluster behind the existing Kong ingress
with Keycloak OIDC SSO.

- **URL**: https://coder.hnatekmar.xyz
- **SSO**: Keycloak (GitHub OAuth upstream). Members of `hnatekmarorg-admin`
  or `algovectra` can sign in.
- **Workspaces**: served on `*.coder.hnatekmar.xyz` (workspace apps).

## Components

| Component | Source | Notes |
|-----------|--------|-------|
| Coder server | `coder/coder` chart 2.36.1 | `argocd/coder.yaml` + `argocd/coder-values.yaml` |
| PostgreSQL | `bitnami/postgresql` chart 16.0.0 | `argocd/coder-postgresql.yaml` (sync-wave -2) |
| Namespace + ExternalSecrets | `argocd/coder/resources.yaml` | `coder` namespace, `coder-db` + `coder-oauth` ESO |
| Keycloak OIDC client | `crossplane/config/keycloak/clients/coder-client.yaml` | client `coder-hnatekmar-xyz` |
| Metrics scraper | `monitoring/scrapers/coder.yaml` | PodMonitor on `prometheus-http` (2112) |

## Ordering (sync waves)

1. `-2` — `coder-postgresql` + `coder-db` ExternalSecret (DB + creds first)
2. `0` — `coder` namespace (in `resources.yaml`)
3. `1` — `coder` chart + Keycloak `Client` + `coder-oauth` ExternalSecret
4. `5` — Keycloak `ClientDefaultScopes`/`ClientOptionalScopes` + `monitoring-resources` picks up the PodMonitor

The `init` ArgoCD Application recurses `argocd/` (directory mode), so the new
`argocd/coder*.yaml` files are picked up automatically. The `monitoring-resources`
app recurses `monitoring/`, so `scrapers/coder.yaml` is picked up the same way.
The `crossplane-init` app recurses `crossplane/config`, so the new Keycloak
client is picked up automatically.

## Secrets (OpenBao)

Two secrets are required in OpenBao **before** the first sync; without them the
ExternalSecrets stay `SecretSyncedError` and Coder/PG wait.

### 1. PostgreSQL credentials — `clusters/coder`

```bash
PASS=$(openssl rand -hex 24)
bao kv put clusters/coder \
  password="$PASS" \
  dsn="postgres://coder:${PASS}@coder-postgresql:5432/coder?sslmode=disable"
```

- `password` → `coder-db-creds/postgres-password` (Bitnami `existingSecret`)
- `dsn`     → `coder-db-creds/CODER_PG_CONNECTION_URL` (Coder `envFrom`)

The DSN host `coder-postgresql` matches the Bitnami release name in
`argocd/coder-postgresql.yaml`.

### 2. OIDC client secret

Created **automatically** by Crossplane when the `coder-hnatekmar-xyz` `Client`
is applied (`writeConnectionSecretToRef` → `crossplane-system/coder-hnatekmar-xyz`).
The `coder-oauth` ExternalSecret bridges `attribute.client_secret` from there
into `coder/coder-hnatekmar-xyz`. No manual OpenBao step.

## DNS

Add an A record for `coder.hnatekmar.xyz` → Kong node IP (same as the other
`*.hnatekmar.xyz` services). For workspace apps, add a wildcard
`*.coder.hnatekmar.xyz` → Kong node IP.

> The cluster's `letsencrypt-prod` issuer is HTTP-01 only (single host), so the
> Coder ingress TLS covers `coder.hnatekmar.xyz` but **not** the wildcard. Kong
> terminates TLS for the apex; workspace-app traffic on `*.coder.hnatekmar.xyz`
> is HTTP upstream (`CODER_WILDCARD_TLS_DISABLE=true`). If you need HTTPS for
> workspace apps later, add a DNS-01 issuer (e.g. `letsencrypt-cloudflare`) and
> a wildcard `Certificate`, then drop `CODER_WILDCARD_TLS_DISABLE`.

## SSO / OIDC

- Issuer: `https://sso.hnatekmar.xyz/realms/master`
- Redirect URI (set on the Keycloak client): `https://coder.hnatekmar.xyz/api/v2/users/oidc/callback`
- Scopes: `openid,profile,email,offline_access` (+ `microprofile-jwt` via the
  client default scopes, which provides the `groups` claim)
- Group/role sync: `CODER_OIDC_GROUP_FIELD=groups`, `CODER_OIDC_USER_ROLE_FIELD=groups`

## Metrics

`CODER_PROMETHEUS_ENABLE=true` exposes Prometheus metrics on the pod's
`prometheus-http` port (2112). The `monitoring/scrapers/coder.yaml` PodMonitor
scrapes it; it appears in Grafana alongside the other targets. (The Coder
Service only exposes the `http` port, so this is a PodMonitor, not a
ServiceMonitor.)

## Verification

After ArgoCD syncs all four apps healthy:

```bash
# Coder API is up
curl -s https://coder.hnatekmar.xyz/api/v2/buildinfo | head

# OIDC login redirects to Keycloak
curl -sI https://coder.hnatekmar.xyz/api/v2/users/oidc/callback | head -1

# Metrics reachable
kubectl -n coder port-forward deploy/coder 2112:2112
curl -s localhost:2112/metrics | head

# Prometheus sees the target
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → Status → Targets → filter "coder"
```

Sign in at https://coder.hnatekmar.xyz → "Sign in with SSO" → Keycloak.

## Adding a workspace

Coder provisions workspaces from templates (Terraform). For a basic Kubernetes
workspace, create a template referencing a `kubernetes` provider pod in the
`coder` namespace (the chart's service account has the needed RBAC). See the
Coder docs: https://coder.com/docs/workspaces
