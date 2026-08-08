# devops — secret registry

KV mount: `devops` (kv-v2). Policies: `devops-github-reader` (read `devops/data/github/*`), `devops` (write).

| Path | Fields | Consumer |
|---|---|---|
| `devops/github/algovectra` | clientId, clientSecret | ESO `github-algovectra` |
| `devops/github/hnatekmarorg` | clientId, clientSecret | ESO `github-hnatekmarorg` |
