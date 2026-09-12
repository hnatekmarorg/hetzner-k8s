# ThingsBoard

IoT platform (Community Edition, monolith `tb-node`) — UI, MQTT, CoAP transports
in one pod. Database is DigitalOcean-managed PostgreSQL via ExternalSecret
(`thingsboard-db-creds` synced from OpenBao `clusters/thingsboard`).

## Exposure model

| Plane | Endpoint | Path |
|---|---|---|
| UI / REST | `https://thingsboard.hnatekmar.xyz` | Kong ingress (8080) |
| **MQTT over TLS** | `thingsboard.hnatekmar.xyz:8883` | **direct pod bind via hostNetwork** |
| MQTT plaintext | `:1883` | node-bound; **firewall-close externally**, TLS-only discipline |

## MQTT TLS

ThingsBoard **terminates MQTT TLS natively** on 8883 — no proxy hop:

- `cert-manager` `Certificate` (`argocd/thingsboard/certificate.yaml`, issuer
  `letsencrypt-prod`, HTTP-01 solved by Kong for the already-live host) writes
  secret `thingsboard-mqtt-tls`.
- The Deployment mounts it at `/certs` and wires `MQTT_SSL_*` PEM env vars
  (paths `tls.crt` / `tls.key`).
- Live reload: TB polls rotated PEMs every 60 s
  (`TB_TRANSPORT_SSL_CERTIFICATE_RELOAD_ENABLED`, default on) — cert renewal is
  a **no-op operationally**: no restarts, no redeploy, no hooks.
- Mount deliberately **not** `subPath`, so kubelet syncs renewed secret content.

Devices authenticate with their access token as the MQTT username; the cert
covers confidentiality only. Trust anchor = ISRG root (LE) — already present in
device OS/SDK trust stores, nothing to distribute.

## Verification

```bash
# cert ready?
kubectl -n thingsboard get certificate thingsboard-mqtt

# TLS handshake with SAN check
openssl s_client -connect <node-ip>:8883 -servername thingsboard.hnatekmar.xyz </dev/null

# end-to-end publish (device token as username)
mosquitto_pub -h thingsboard.hnatekmar.xyz -p 8883 -u "$ACCESS_TOKEN" \
  -t v1/devices/me/telemetry -m '{"temperature":23.7}'
```

The UI connectivity widget (Devices → check connection) also prints ready-made
MQTTS commands (`DEVICE_CONNECTIVITY_MQTTS_ENABLED`).

## Firewall / operator notes

- Hetzner Cloud firewall: allow TCP **8883**; close **1883** once devices moved.
- `hostNetwork: true` means the pod binds node ports directly — keep 8883 free
  on the node ( DaemonSet/port collisions would surface as pod restart-loops).

## Follow-ups (not in this change)

- Image bump `4.2.0 → 4.3.x` (sequential upgrade path, see TB upgrade docs).
- Resources + probes on the Deployment (AGENTS.md asks for them on prod workloads).
- Optional: dedicated `mqtt.hnatekmar.xyz` name if UI/ingress host ever migrates.
