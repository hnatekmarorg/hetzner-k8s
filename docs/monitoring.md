# Monitoring Stack

The monitoring stack runs in the `monitoring` namespace. The ArgoCD Applications
live under `argocd/monitoring/` (created by `init`): `kube-prometheus-stack`,
`loki`, and `monitoring-resources`. The `monitoring-resources` app applies the
raw resources in `monitoring/` (namespace, dashboards, scrapers, ExternalSecret)
and syncs *after* kube-prometheus-stack and the crossplane-config apps (sync
wave 5) so the Prometheus CRDs and the Keycloak client secret already exist.

## Components

| Component | Helm chart | Version | Notes |
|-----------|-----------|---------|-------|
| Prometheus + Alertmanager + Grafana | `kube-prometheus-stack` | 88.3.0 | Also installs kube-state-metrics, node-exporter, and the default Kubernetes dashboards |
| Loki | `loki` | 18.7.6 | Monolithic (single-binary) mode, filesystem storage |
| Promtail | `promtail` | 6.17.1 | DaemonSet shipping container logs to Loki |

## Access

- **Grafana**: https://monitoring-hetzner.hnatekmar.xyz
- **SSO**: sign in with Keycloak (GitHub OAuth). Only members of the
  `algovectra` or `hnatekmarorg-admin` groups get **Admin** access:
  - `role_attribute_path` maps the token `groups` claim (= Keycloak realm
    roles via the `microprofile-jwt` scope) to `Admin`.
  - `role_attribute_strict: true` denies everyone else.
  - Local login form and the initial admin account are disabled (SSO only).
- The Keycloak client secret is synced from the Crossplane connection secret
  (`crossplane-system/grafana-hnatekmar-xyz` -> `monitoring/grafana-hnatekmar-xyz`)
  via the `kubernetes-crossplane` ClusterSecretStore and `grafana-oauth`
  ExternalSecret.

## Data sources

- **Prometheus**: default, wired automatically by kube-prometheus-stack.
- **Loki**: configured via `grafana.additionalDataSources`
  (`http://loki.monitoring.svc.cluster.local:3100`). Auth is disabled
  (`auth_enabled: false`), so no `X-Scope-OrgID` header is needed. Container
  logs are shipped to it by the `promtail` DaemonSet.

## Dashboards

Default Kubernetes dashboards (cluster, nodes, pods, networking, workloads,
etc.) ship with kube-prometheus-stack. Extra dashboards are provisioned as
ConfigMaps with the `grafana_dashboard: "1"` label (picked up by the Grafana
sidecar):

| Dashboard | Source |
|-----------|--------|
| Loki Logs | `monitoring/dashboards/loki-logs.yaml` |
| cert-manager | `monitoring/dashboards/cert-manager.yaml` |
| External Secrets Operator | `monitoring/dashboards/external-secrets.yaml` |
| Kong | `monitoring/dashboards/kong.yaml` |

### Adding a dashboard

1. `helm template` or download the dashboard JSON from grafana.com.
2. Rewrite datasource references to the deployed uids (`prometheus`, `loki`)
   - provisioned dashboards do not resolve `${DS_PROMETHEUS}` template vars.
3. Drop the JSON into a ConfigMap in `monitoring/dashboards/` with the
   `grafana_dashboard: "1"` label and commit.

## Metrics scrapers

Metrics targets are defined in `monitoring/scrapers/`. Each
ServiceMonitor/PodMonitor must carry the `release: kube-prometheus-stack`
label so the kube-prometheus-stack Prometheus picks it up. Because they depend
on the `monitoring.coreos.com` CRDs installed by kube-prometheus-stack, they
are applied by the `monitoring-resources` app (sync wave 5) rather than by the
root `init` app, avoiding first-sync errors.

| Target | Kind | Endpoint |
|--------|------|----------|
| cert-manager | ServiceMonitor | `cert-manager` service port 9402 (`/metrics`) |
| External Secrets Operator | PodMonitor | ESO controller pod port `metrics` (8080) |
| Kong | ServiceMonitor (chart) | proxy `status` port `/metrics` + KIC `cmetrics` (10255), created by the kong chart (`argocd/kong.yaml`, `serviceMonitor.enabled: true`) |

Kong traffic metrics (request counts, status codes, latency, bandwidth) come
from the built-in Prometheus plugin, enabled globally via
`argocd/kong/prometheus-plugin.yaml` (a `KongClusterPlugin`).
