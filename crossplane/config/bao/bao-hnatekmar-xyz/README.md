# OpenBao — bao.hnatekmar.xyz Configuration

Declarative OpenBao config managed by **Crossplane** (`vault.upbound.io` provider) and synced by **ArgoCD** from `crossplane/config/` (recursive).

> **Rule that shapes the layout:** renaming a Crossplane resource = delete + recreate in OpenBao. File *moves* are no-ops to Argo; identity *renames* recreate the object. Prefer moves; rename only deliberately (preproduction).

## Layout convention

- **`auth/`** — auth *backends* + config, one file per method (`kubernetes.yaml`, `kubernetes-config.yaml`, `approle.yaml`, `oidc.yaml`).
- **`roles/`** — auth *roles* grouped by method: `roles/kubernetes/`, `roles/approle/`, `roles/oidc/`. File name == resource identity.
- **`policies/`** — global/cross-cutting policies (e.g. `admin-identity`).
- **`<tenant>/`** — one directory per KV mount/tenant: `mount.yaml`, `policies/` (scoped to that mount only), optional `ssh/`, and a `README.md` acting as that mount's **secret registry**.
- **Naming:** `metadata.name` == `forProvider.name` == file name.
- **Policy scoping:** a policy grants its **own mount only**. Cross-mount access uses a dedicated reader policy + role, never a widened tenant policy.

### Per-tenant agents

Each tenant gets its own `*-agent` machine identity (kubernetes SA role + policy scoped to its mount). Today:
- `hermes-agent` — kubernetes (in-cluster SA `hermes/hermes`) + approle (for `.180` Hermes). Policy: `hermes-agent` → `hermes/*`.
- `bao-hnatekmar-xyz` (kubernetes SA `external-secrets/external-secrets`) — ESO stores. Policies: `clusters-secret-creator`, `devops-github-reader`, `hermes-agent`.
- Planned: `algovectra-agent` etc. as new agents land (e.g. runpod scaler, Phase 4).

## Secret registry

KV path scheme (CLI): `<mount>/<service>/<secret>`. The internal `/data/` segment is a CLI↔API mapping detail — consumers use `bao kv get <mount>/<path>`.

| Mount | Path | Fields | Consumer | Policy gate |
|---|---|---|---|---|
| `algovectra` | `github` | token | ESO / bots | `algovectra` |
| `algovectra` | `runpod` | api_key, components_url, pizza_url | runpod scaler (planned), `.envrc` | `algovectra` |
| `algovectra` | `s3/hot`, `s3/cold` | host, ACCESS_KEY, SECRET_KEY | runpod scaler, pods | `algovectra` |
| `devops` | `github/algovectra` | clientId, clientSecret | ESO `github-algovectra` | `devops-github-reader` |
| `devops` | `github/hnatekmarorg` | clientId, clientSecret | ESO `github-hnatekmarorg` | `devops-github-reader` |
| `hermes` | `github` | token, algo | Hermes agent (`.180` approle) | `hermes-agent` |
| `clusters` | `admin/keycloak` | username, password | ESO `keycloak` | `clusters-secret-creator` |
| `clusters` | `keycloak/db` | username, password | keycloak | `clusters-secret-creator` |
| `clusters` | `digitalocean` | token | crossplane/digitalocean | `clusters-secret-creator` |

*Paths marked "runtime convention" should be confirmed against the live instance (OpenBao was sealed at reorg time).*

### Add a new secret

1. Pick the tenant mount (`<mount>/<service>/<name>`).
2. Add a row to the tenant's `README.md` registry.
3. Ensure a policy scoped to that mount grants the right capabilities.
4. Grant access to the consumer's agent/role, not by widening a tenant policy.

## Auth methods

- **kubernetes** (`path: kubernetes`) — in-cluster SA auth (external-secrets, hermes).
- **approle** (`path: approle`) — machine identity for off-cluster hosts (`.180` Hermes).
- **oidc** (`path: oidc`) — SSO via Keycloak (`sso.hnatekmar.xyz`). Roles: `admin`, `algovectra`, `hnatekmarorg`.

OIDC client secret is provisioned by the Keycloak client resource (`crossplane/config/keycloak/clients/bao-client.yaml`), not a KV secret.
