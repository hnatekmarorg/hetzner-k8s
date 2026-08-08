# hermes — secret registry

KV mount: `hermes` (kv-v2). Policy: `hermes-agent` (own mount only).

| Path | Fields | Consumer |
|---|---|---|
| `hermes/github` | token, algo | Hermes agent (`.180`, approle `hermes-agent`) |

Agent identities: kubernetes SA `hermes/hermes` (in-cluster) + approle role `hermes-agent` (off-cluster, e.g. `.180`).
