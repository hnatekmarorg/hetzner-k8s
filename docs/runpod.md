# Monitoring RunPod GPU instances

Connect your RunPod GPU pods to the homelab monitoring stack (Prometheus + Grafana + Loki) at monitoring-hetzner.hnatekmar.xyz.

## Architecture

| Data plane | RunPod side | Homelab side | Direction |
|---|---|---|---|
| RunPod account / pods / GPU pricing | — | `runpod-exporter` (pulls `api.runpod.io`) | pull from homelab |
| GPU + system metrics | Grafana Alloy scraping DCGM + node exporters | Prometheus **Remote Write** receiver | push from pod |
| Container/system logs | Grafana Alloy | Loki `/loki/api/v1/push` | push from pod |

Because RunPod instances are ephemeral and sit behind RunPod's NAT, the homelab cannot
pull/scrape their metrics. The pods must **push** (Remote Write for metrics, Loki push for
logs). The only pull is the RunPod **API** exporter, which the homelab scrapes directly.

## Transport: Kong + key-auth (recommended)

The push endpoints are exposed through the existing Kong ingress (no changes to the
Kubernetes node's networking):

| Endpoint | Purpose |
|---|---|
| `https://loki.hnatekmar.xyz/loki/api/v1/push` | Loki log ingestion |
| `https://prometheus-push.hnatekmar.xyz/api/v1/write` | Prometheus Remote Write |

Both are gated by Kong `key-auth` (`apikey` header). The token lives in OpenBao and is
synced into the `monitoring/monitoring-pusher-key-auth` Secret by external-secrets; the
Kong consumer references that Secret (KIC 3.x credential model, keyed by the
`konghq.com/credential: key-auth` **label**), so **no key is committed to git**.

> **DNS (required before the endpoints work):** add A records for
> `loki.hnatekmar.xyz` and `prometheus-push.hnatekmar.xyz` pointing at
> `88.198.65.246` (the Kong node IP), like the other `*.hnatekmar.xyz` services.
> The wildcard currently resolves new subdomains to the wrong IP, which blocks
> Let's Encrypt HTTP-01 validation (and thus the TLS secrets Kong needs to route).

> Why not Tailscale? A host-level Tailscale that manipulates routes/tables/TUN on the
> Kubernetes node risks interfering with the k3s CNI (flannel) and kube-proxy. Keep the
> node's networking untouched. If you want a private overlay later, run Tailscale/userspace
> strictly inside the RunPod pod image and on a separate VM, never on the k8s node.

### Provision the push token (homelab side)

```bash
# generate a strong random token
TOKEN=$(openssl rand -hex 32)

# store it in Vault
bao kv put clusters/monitoring/push-token token="$TOKEN"

# external-secrets syncs it -> Secret monitoring/monitoring-pusher-key-auth
# (annotation konghq.com/credential: key-auth, key: <token>)
# KIC creates the Kong credential from that Secret automatically.
```

### Provision the RunPod API key (homelab side)

```bash
bao kv put algovectra/runpod api_key=<RUNPOD_API_KEY> components_url=... pizza_url=...
# ESO syncs it -> Secret monitoring/runpod -> runpod-exporter becomes Ready
```

## RunPod side

Run on each GPU pod (docker-compose or add to your image):

```yaml
services:
  node-exporter:
    image: prom/node-exporter:v1.9.1
    network_mode: host
    pid: host
    command:
      - --path.rootfs=/host
    volumes:
      - /:/host:ro,rslave

  dcgm-exporter:
    image: nvidia/dcgm-exporter:4.5.0
    runtime: nvidia
    ports: ["9400:9400"]

  alloy:
    image: grafana/alloy:v1.11.1
    ports: ["12345:12345"]
    environment:
      - RUNPOD_PUSH_TOKEN=${RUNPOD_PUSH_TOKEN}
      - RUNPOD_POD_ID=${RUNPOD_POD_ID}
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
```

`config.alloy`:

```alloy
prometheus.scrape "node" {
  targets    = [{"__address__" = "localhost:9100"}]
  forward_to = [prometheus.remote_write.default.receiver]
}
prometheus.scrape "dcgm" {
  targets    = [{"__address__" = "localhost:9400"}]
  forward_to = [prometheus.remote_write.default.receiver]
}

prometheus.remote_write "default" {
  endpoint {
    url = "https://prometheus-push.hnatekmar.xyz/api/v1/write"
    headers = {
      "apikey" = env("RUNPOD_PUSH_TOKEN"),
    }
  }
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}
loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.docker.containers.targets
  forward_to = [loki.write.default.receiver]
}
loki.write "default" {
  endpoint {
    url = "https://loki.hnatekmar.xyz/loki/api/v1/push"
    headers = {
      "apikey" = env("RUNPOD_PUSH_TOKEN"),
    }
  }
}
```

To tell pods apart, add a `pod_id` label in the scrape and log pipelines:

```alloy
prometheus.scrape "node" {
  targets    = [{"__address__" = "localhost:9100"}]
  forward_to = [prometheus.remote_write.default.receiver]
  extra_labels = {
    pod_id = env("RUNPOD_POD_ID"),
  }
}
prometheus.scrape "dcgm" {
  targets    = [{"__address__" = "localhost:9400"}]
  forward_to = [prometheus.remote_write.default.receiver]
  extra_labels = {
    pod_id = env("RUNPOD_POD_ID"),
  }
}
```

## Verification

- Push metrics: `curl -H "apikey: $TOKEN" "https://prometheus-push.hnatekmar.xyz/api/v1/write"` returns 405/400 (not 401) once auth passes.
- Logs land in the **Loki Logs** dashboard under labels `container`, `namespace`, `pod_id`.

## Homelab files

- Push ingress/plugin/consumer: `monitoring/ingress-push.yaml`, `argocd/kong/key-auth.yaml`, `monitoring/kong-consumer-push.yaml`
- Remote Write receiver: `enableRemoteWriteReceiver: true` in `argocd/monitoring/kube-prometheus-stack.yaml`
- API exporter + dashboard: `monitoring/exporters/runpod/`, `monitoring/dashboards/runpod.yaml`
- Secrets: `monitoring/external-secret-runpod.yaml`, `monitoring/external-secret-push-token.yaml` (in `kong-consumer-push.yaml`)
