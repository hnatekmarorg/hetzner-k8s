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

## Recommended transport: Tailscale

Expose Loki and Prometheus only on a Tailscale tailnet, never on the public internet
(Loki has `auth_enabled: false`; publishing it publicly would allow anyone to write logs).

- RunPod [officially supports Tailscale](https://github.com/runpod/containers/tree/main/official-templates/tailscale).
- ACLs replace bearer tokens: access is decided by tailnet policy, not a secret to sign.
- The homelab runs a small `tailscale serve` proxy that maps (mTLS) `https://loki.<tailnet>/` → `loki.monitoring:3100` and `https://prom.<tailnet>/` → `kube-prometheus-stack-prometheus.monitoring:9090`.

Alternative (only if you accept public endpoints): expose the same two services through
the existing Kong ingress (e.g. `loki.hnatekmar.xyz`, `prometheus-push.hnatekmar.xyz`)
with Kong `key-auth`; the token lives in Vault and is provisioned once manually (Kong 2.47
here has the admin API bound to `127.0.0.1` inside the pod, so the credential is created
manually, not via GitOps).

## Homelab side (this repo)

Already added:

- **RunPod API exporter** — `monitoring/exporters/runpod/runpod-exporter.yaml`
  (Deployment + Service + ConfigMap script, python slim image, no registry needed),
  scraped by `monitoring/scrapers/runpod.yaml`. Metrics: `runpod_pod_status`,
  `runpod_pod_cost_per_hour_usd`, `runpod_account_balance_usd`,
  `runpod_gpu_lowest_price_usd_hour`, `runpod_gpu_max_count`.
- **Secret wiring** — `monitoring/external-secret-runpod.yaml` syncs
  `algovectra/runpod` (`api_key`) from OpenBao via the `local-algovectra` store.
- **Remote Write receiver** — `prometheus.prometheusSpec.enableRemoteWriteReceiver: true`
  in `argocd/monitoring/kube-prometheus-stack.yaml`.
- **Dashboard** — `monitoring/dashboards/runpod.yaml` (balance, pods, GPU pricing).

### Provision the RunPod API key

```bash
bao kv put algovectra/runpod api_key=<RUNPOD_API_KEY> components_url=... pizza_url=...
# ESO syncs it -> Secret monitoring/runpod -> runpod-exporter becomes Ready
```

### Expose push endpoints (Tailscale, homelab side)

```bash
# store the tailnet auth key in Vault for gitops provisioning
bao kv put devops/tailscale auth_key=<TS_AUTH_KEY>
```

Deploy (see `docs/`) a `tailscale` pod with:

```bash
tailscale up --authkey=<from vault> --hostname=k8s-monitoring
tailscale serve --bg --https=443 http://loki.monitoring:3100
# second service name for Prometheus remote-write:
tailscale serve --bg --set-path /api/v1/write --https=443 <tailnet>:9090
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

  tailscale:
    image: tailscale/tailscale:v1.82
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_EXTRA_ARGS=--hostname=runpod-${RUNPOD_POD_ID}
    cap_add: [NET_ADMIN, SYS_MODULE]
    volumes:
      - /var/lib/tailscale:/var/lib/tailscale

  alloy:
    image: grafana/alloy:v1.11.1
    ports: ["12345:12345"]
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./config.alloy:/etc/alloy/config.alloy:ro
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
```

`config.alloy` (endpoints are the tailnet hostnames from `tailscale serve`):

```alloy
discovery.kubernetes "pods" {}

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
    url = "https://prom.<tailnet>.ts.net/api/v1/write"
  }
}

loki.source.docker "containers" {
  host = "unix:///var/run/docker.sock"
  targets = discovery.docker.containers.targets
  forward_to = [loki.write.default.receiver]
}
discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

loki.write "default" {
  endpoint {
    url = "https://loki.<tailnet>.ts.net/loki/api/v1/push"
  }
}
```

Then in Grafana (`monitoring-hetzner.hnatekmar.xyz`), Remote Write series show up
automatically under `instance="localhost:9100"`; add `pod_id` as an extra label in
Alloy if you run several pods:

```alloy
// in prometheus.scrape.node & dcgm, add relabel
relabel.rule "pod_id" {
  rule {
    target_label = "pod_id"
    replacement  = env("RUNPOD_POD_ID")
  }
}
```

Logs land under labels `namespace`, `container`, `pod` from the Docker discovery and are
queryable in the **Loki Logs** dashboard.

## GPU dashboards

- The `runpod` dashboard covers account/pods/pricing.
- For per-GPU utilization/thermals scraped over Remote Write (`dcgm_gpu_*` series), add a
  dashboard selecting `pod_id` + `gpu` (the standard "NVIDIA DCGM Exporter" dashboard from
  grafana.com works; repoint datasource uid to `prometheus` and add `pod_id` filters).
