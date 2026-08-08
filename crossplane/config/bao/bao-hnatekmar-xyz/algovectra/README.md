# algovectra — secret registry

KV mount: `algovectra` (kv-v2). Policy: `algovectra` (own mount only), `algovectra-ssh` (SSH engine).

| Path | Fields | Consumer |
|---|---|---|
| `algovectra/github` | token | ESO / bots |
| `algovectra/runpod` | api_key, components_url, pizza_url | runpod scaler (planned), `.envrc` |
| `algovectra/s3/hot` | host, ACCESS_KEY, SECRET_KEY | runpod scaler, pods |
| `algovectra/s3/cold` | host, ACCESS_KEY, SECRET_KEY | runpod scaler, pods |

SSH engine: `algovectra-ssh` (CA, mount, role) — see `ssh/`.

> Cross-mount access (e.g. `hermes/*`) is **not** granted by this tenant's policy. Use a dedicated `algovectra-agent` identity if needed.
