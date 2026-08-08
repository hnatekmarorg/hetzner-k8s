# clusters — secret registry

KV mount: `clusters` (kv-v2). Policy: `clusters-secret-creator`.

| Path | Fields | Consumer |
|---|---|---|
| `clusters/admin/keycloak` | username, password | ESO `keycloak` (crossplane/secrets/keycloak.yaml) |
| `clusters/keycloak/db` | username, password | keycloak |
| `clusters/digitalocean` | token | Crossplane DigitalOcean provider |

Read via ESO `ClusterSecretStore local` (base path `clusters`).
