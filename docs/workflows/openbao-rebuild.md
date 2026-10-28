# OpenBao Rebuild Runbook

Use this runbook to rebuild OpenBao from a logical backup. The rebuild removes the
leaked token store, keeps the KV data, and rotates the SSH CA keys. Plan a maintenance
window. External Secrets and Crossplane OpenBao resources are unavailable during the
window.

## Prerequisites

- The encrypted backup archive and its age private key, outside the Git repository.
- `kubectl`, `jq`, `age`, and the OpenBao CLI inside the pod.
- The old SSH CA public keys from the backup.
- `argocd/openbao/values.yaml` pinned to the tested OpenBao image.
- A maintenance window with enough time to re-enroll the SSH hosts and clients.

## 1. Freeze GitOps

Pause the app-of-apps and the OpenBao applications. This stops ArgoCD from recreating
the StatefulSet during the wipe.

```bash
kubectl -n argocd patch application.argoproj.io init --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application.argoproj.io openbao --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application.argoproj.io crossplane-config --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

## 2. Stop OpenBao

```bash
kubectl -n openbao-system scale statefulset openbao --replicas=0
kubectl -n openbao-system wait --for=delete pod/openbao-0 --timeout=120s
```

## 3. Optional full database copy

The logical backup is the primary backup. A full copy gives a rollback path.

Find the local-path directory:

```bash
kubectl get pv -o json \
  | jq -r '.items[] | select(.spec.claimRef.name=="data-openbao-0") | .spec.hostPath.path'
```

Copy that directory to a separate location on the node. Use a privileged debug pod.
Keep the copy until the rebuild passes verification.

## 4. Remove the old data

```bash
kubectl -n openbao-system delete pvc data-openbao-0
```

Confirm that the PV and the host directory are gone. If the PV is retained, remove the
host directory by hand.

## 5. Recreate OpenBao

Resume the OpenBao application. The chart creates a new PVC and pod. The pod starts
uninitialized.

```bash
kubectl -n argocd patch application.argoproj.io openbao --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n openbao-system wait --for=condition=Ready pod/openbao-0 --timeout=300s
```

## 6. Initialize and unseal

```bash
kubectl -n openbao-system exec openbao-0 -- \
  bao operator init -key-shares=1 -key-threshold=1 -format=json \
  > /root/openbao-init.json
```

Store the unseal key and root token in the Kubernetes secrets. Keep the TLS keys in
`bao-secret`.

```bash
UNSEAL=$(jq -r '.unseal_keys_b64[0]' /root/openbao-init.json)
ROOT=$(jq -r '.root_token' /root/openbao-init.json)

kubectl -n openbao-system patch secret bao-unseal-key --type=merge \
  -p "{\"data\":{\"key\":\"$(printf '%s' "$UNSEAL" | base64 -w0)\"}}"
kubectl -n openbao-system patch secret bao-secret --type=merge \
  -p "{\"data\":{\"root_token\":\"$(printf '%s' "$ROOT" | base64 -w0)\"}}"
kubectl -n crossplane-system patch secret openbao-hnatekmar-xyz --type=merge \
  -p "{\"data\":{\"config\":\"$(printf '{\"token\":\"%s\"}' "$ROOT" | base64 -w0)\"}}"

kubectl -n openbao-system exec openbao-0 -- bao operator unseal "$UNSEAL"
```

Remove `/root/openbao-init.json` after you store the key.

## 7. Re-import KV secrets

Use the backup files. For each file, send `.data.data` to the mount path. The path
`algovectra/bombastica/config` becomes `/v1/algovectra/data/bombastica/config`.

```bash
for f in <backup>/kv/**/*.json; do
  path=${f#<backup>/kv/}
  path=${path%.json}
  mount=${path%%/*}
  rest=${path#*/}
  jq -c '.data.data' "$f" \
    | kubectl -n openbao-system exec -i openbao-0 -- \
        curl -sS -X POST \
        -H "X-Vault-Token: $ROOT" \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "http://127.0.0.1:8200/v1/${mount}/data/${rest}" >/dev/null
done
```

Run the loop inside the pod or port-forward the OpenBao service.

## 8. Recreate the OpenBao configuration

Resume the Crossplane configuration application. Crossplane recreates the mounts,
auth backends, policies, SSH CAs, and roles.

```bash
kubectl -n argocd patch application.argoproj.io crossplane-config --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Wait for the `SecretBackendRole` and `SecretBackendCA` resources to report
`Synced=True`.

## 9. Rotate the SSH CA trust

The rebuild generated new SSH CA keys. Install both the new and old CA public keys on
each host.

Extract the old public keys from the backup:

```bash
jq -r '.data.public_key' <backup>/ssh-ca/hnatekmarorg-ssh-infra.json > old-infra-ca.pub
jq -r '.data.public_key' <backup>/ssh-ca/hnatekmarorg-ssh-dev.json > old-dev-ca.pub
```

Run the updated `enroll.sh` on each host:

```bash
enroll.sh --class infra trust --previous-ca old-infra-ca.pub
enroll.sh --class dev trust --previous-ca old-dev-ca.pub
```

Re-enroll each client certificate:

```bash
enroll.sh --class infra issue
enroll.sh --class dev issue
```

Test a login with a new certificate and a login with an old certificate. After the old
certificates expire, retire the old CA:

```bash
enroll.sh --class infra trust
enroll.sh --class dev trust
```

The legacy `hnatekmarorg-ssh` and `algovectra-ssh` CAs also rotate. Re-enroll their
consumers, or retire those mounts.

## 10. Verify

- `bao status` reports `Sealed false`.
- All ArgoCD applications are Synced and Healthy.
- ExternalSecrets are synced.
- A new SSH certificate logs in.
- The provider-vault logs show no `Writing role` loop.

## 11. Clean

- Delete the full database copy after verification.
- Remove the old init file, unseal copies, and root token copies.
- Move the age private key offline.
- Remove the old CA public keys after the old certificates expire.

## Rollback

If the rebuild fails, restore the full database copy to the PVC path. Recreate the PVC
and pod. Do not use the old root token until the data is restored.
