# OpenBao Migration Plan: File Storage → Raft Storage

**Date**: 2026-03-07
**Issue**: Inode exhaustion (100% usage) caused by `file` storage backend
**Root Cause**: File storage creates 2.3M+ small files; Raft uses single `raft.db` file
**Downtime**: ~15-30 minutes for migration and reconfiguration

---

## Pre-Migration Backup

**IMPORTANT**: The following configurations are maintained in infrastructure-as-code via Crossplane and do NOT need manual reconfiguration:

✅ **Managed by Crossplane (Automatic)**:
- **Kubernetes Auth Methods** (`devops/`, `oidc/`)
  - Located: `crossplane/config/keycloak/clients/*.yaml`
  - Auto-provisioned by Crossplane after migration
- **SSH Secret Engines** (`algovectra-ssh/`)
  - Managed via Crossplane compositions
  - Will be recreated automatically
- **Policy configurations**
  - Stored as Kubernetes manifests
  - Applied via Crossplane

✅ **Persistent Data** (Not lost, but re-initialized):
- **KV v2 Engines** (`algovectra/`, `clusters/`)
  - Secrets themselves will be migrated if using `-migrate-to=raft`
  - Otherwise, re-add secrets after migration (recommended for data refresh)

---

## Migration Procedure

### Phase 1: Stop OpenBao (Time: 2 minutes)

```bash
# Stop the OpenBao pod - required for storage backend change
kubectl scale deployment -n openbao-system openbao --replicas=0

# Wait for pod termination
kubectl wait --for=delete pod -n openbao-system -l app.kubernetes.io/name=openbao --timeout=60s
```

### Phase 2: Backup & Clear Old Storage (Time: 5 minutes)

**Option A**: Preserve data (requires `-migrate-to=raft` flag - NOT SUPPORTED for cross-backend migration)
**Option B**: Clean migration (RECOMMENDED for production)

```bash
# Backup existing secrets that aren't in Crossplane
export VAULT_ADDR=https://bao.hnatekmar.xyz
export VAULT_TOKEN="s.1Jl5g42IPYUota1GGAyhEJ0E"

# List all secrets in non-system engines
bao kv list algovectra/ > /tmp/algovectra-secrets.txt
bao kv list clusters/ > /tmp/clusters-secrets.txt

# Clear old file storage (CLEAN SLATE)
ssh root@static.26.154.224.46.clients.your-server.de << 'EOF'
# Backup configmap for reference
kubectl get configmap -n openbao-system openbao-config -o yaml > /tmp/openbao-config-backup.yaml

# Remove old file storage directory
rm -rf /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0/*

# Verify cleanup
df -i /
EOF
```

### Phase 3: Update Configuration (Time: 2 minutes)

Configuration already updated in `argocd/openbao/values.yaml`:
- ✅ Storage backend changed from `file` to `raft`
- ✅ Raft tuning parameters configured
- ✅ Audit logs set to stdout
- ✅ Token TTL limits preserved

### Phase 4: ArgoCD Sync (Time: 5 minutes)

```bash
# ArgoCD will automatically detect and apply the change
argocd app sync openbao

# Monitor sync progress
argocd app get openbao --watch

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -n openbao-system openbao-0 --timeout=300s
```

### Phase 5: Initialize & Unseal (Time: 5 minutes)

```bash
# The Helm chart handles initialization automatically
# If using Shamir (current config):
export VAULT_ADDR=https://bao.hnatekmar.xyz
export VAULT_TOKEN="s.1Jl5g42IPYUota1GGAyhEJ0E"

# Check status - should show "Storage Type: raft"
bao status

# Verify Raft is healthy
curl -k -H "X-Vault-Token: $VAULT_TOKEN" https://bao.hnatekmar.xyz/v1/sys/storage/raft/status
```

### Phase 6: Verify Crossplane Connectivity (Time: 2 minutes)

```bash
# Check Crossplane can still connect to OpenBao
kubectl get providerconfig -n crossplane-system bao-hnatekmar-xyz

# Check OpenBao logs for errors
kubectl logs -n openbao-system openbao-0 --tail=50

# Verify Crossplane still can provision resources
kubectl get managed -A | head -20
```

### Phase 7: Re-seed Secrets (Time: 5 minutes) - ONLY FOR SECRETS NOT IN CROSSPLANE

```bash
# Only if you have KV secrets that aren't in Crossplane:
# Re-add algovectra secrets (if any)
bun algovectra put airflow/admin < /tmp/algovectra-backup.txt

# Re-add cluster configs (if any)
bun clusters put staging/config < /tmp/clusters-backup.txt
```

---

## Post-Migration Verification

### 1. Verify Storage Type
```bash
kubectl exec -n openbao-system openbao-0 -- bao status
# Expected: Storage Type: raft
```

### 2. Verify Raft Health
```bash
curl -k -H "X-Vault-Token: $VAULT_TOKEN" https://bao.hnatekmar.xyz/v1/sys/storage/raft/status
# Expected: healthy: true
```

### 3. Verify Inode Usage
```bash
ssh root@static.26.154.224.46.clients.your-server.de "df -i /"
# Expected: Inode usage should be significantly lower
# Old: 2479040 2479040     0 100% /
# New: Should show free inodes available
```

### 4. Verify File Count
```bash
# Check OpenBao PVC file count
ssh root@static.26.154.224.46.clients.your-server.de << 'EOF'
find /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0 -type f | wc -l
EOF
# Expected: Should be minimal (just config files + raft.db)
# Old: 2,368,196 files
# New: <10 files
```

### 5. Verify Crossplane Resources
```bash
# Check that existing Crossplane resources still work
kubectl get managed -A | grep -E "ssh|vault"

# Verify new resources can be created
# Example: Create a test secret engine (if applicable)
```

### 6. Verify ArgoCD Sync
```bash
argocd app list | grep openbao
argocd app get openbao
# Expected: Sync status: Synced, Health: Healthy
```

---

## What Needs to Be Reconfigured After Migration

### ❄️ Automatic (Crossplane + Kubernetes Secrets)
- ✅ **Kubernetes Auth Methods** (`devops/`, `oidc/`): Auto-created by Crossplane
- ✅ **SSH Secret Engines**: Managed by Crossplane compositions
- ✅ **Token/Keycloak integration**: Managed by Crossplane clients config

### ❄️ Manual (Only if you have custom KV secrets not in Git/Crossplane)
- ⚠️ **KV v2 Secrets** (`algovectra/`, `clusters/`)
  - If you manually added secrets to these engines, re-add them
  - Most production secrets should be in Crossplane manifests, not manually managed
  - Command: `bao kv put <path> <key=value>`

### ❄️ Audit Logs
- ✅ **Already**: Configured to stdout (handled by Kubernetes log driver)
- ✅ **No action needed**: Logs go to `kubectl logs -n openbao-system openbao-0`

---

## Rollback Plan (Migration Fails)

**If migration fails, rollback to file storage:**

```bash
# 1. Stop OpenBao
kubectl scale deployment -n openbao-system openbao --replicas=0

# 2. Revert config (git checkout values.yaml)
cd /home/martin/Documents/Programming/sandbox/hetzner-k8s
git checkout argocd/openbao/values.yaml

# 3. Restore backup if you made one
ssh root@static.26.154.224.46.clients.your-server.de << 'EOF'
# If you backed up the storage directory
mv /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0.backup/* \
   /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0/
EOF

# 4. Sync ArgoCD
argocd app sync openbao

# 5. Wait for recovery
kubectl wait --for=condition=ready pod -n openbao-system openbao-0 --timeout=300s
```

---

## Monitoring After Migration

### 1. Inode Usage (check daily for first week)
```bash
ssh root@static.26.154.224.46.clients.your-server.de "df -i /"
```

### 2. Raft File Growth
```bash
ssh root@static.26.154.224.46.clients.your-server.de << 'EOF'
ls -lh /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0/raft.db
EOF
```

### 3. OpenBao Health
```bash
argoget app get openbao --server-side
kubectl logs -n openbao-system openbao-0 --tail=100 --since=1h | grep -i error
```

### 4. Crossplane Connectivity
```bash
kubectl describe providerconfig -n crossplane-system bao-hnatekmar-xyz
kubectl get managed -A | grep -v none | wc -l
```

---

## Migration Timeline

| Phase | Duration | Description |
|-------|----------|-------------|
| Stop OpenBao | 2 min | Scale deployment to 0 |
| Backup & Clear | 5 min | Backup configs, clean old storage |
| ArgoCD Sync | 5 min | Deploy new Raft config |
| Initialize & Unseal | 5 min | Initialize Raft storage |
| Verify Crossplane | 2 min | Check Crossplane connectivity |
| Re-seed Secrets | 5 min | Only for manual-seeded secrets |
| Verification | 5 min | Post-migration checks |
| **Total** | **~29 min** | |

---

## Success Criteria

- ✅ OpenBao pod healthy (Ready=true)
- ✅ `bao status` shows: Storage Type: raft
- ✅ Inode usage < 50% (was 100%)
- ✅ File count < 20 (was 2.3M+)
- ✅ Crossplane providerconfig healthy
- ✅ No errors in OpenBao logs
- ✅ Existing Crossplane resources still functional

---

## Troubleshooting

### Issue: OpenBao fails to start
```bash
# Check logs
kubectl logs -n openbao-system openbao-0

# Common causes:
# - PVC not mounted: Check PVC status
# - Config error: Check ConfigMap syntax
# - Permission denied: Check storage permissions
```

### Issue: Crossplane can't connect
```bash
# Check secret still exists
kubectl get secret openbao-hnatekmar-xyz -n crossplane-system

# Check secret token is valid
export VAULT_TOKEN=$(kubectl get secret openbao-hnatekmar-xyz -n crossplane-system -o jsonpath='{.data.config}' | jq -r '.token')
curl -k https://bao.hnatekmar.xyz/v1/sys/health-check -H "X-Vault-Token: $VAULT_TOKEN"

# Check providerconfig status
kubectl describe providerconfig -n crossplane-system bao-hnatekmar-xyz
```

### Issue: Inode usage still high
```bash
# Find what's using inodes
ssh root@static.26.154.224.46.clients.your-server.de "for d in /*; do echo $d: $(find $d -type f 2>/dev/null | wc -l); done | sort -k2 -rn | head -10"

# Check if old storage has orphaned files
ssh root@static.26.154.224.46.clients.your-server.de "find /var/lib/rancher/k3s/storage/pvc-db8e6032-8e71-40db-afd1-9367218bd5c1_openbao-system_data-openbao-0 -type f -ls"
```

---

## Notes

- **Why clean migration?**: OpenBao doesn't support direct migration from `file` to `raft` backend
- **Why Crossplane?**: Your auth methods and secret engines are managed declaratively via Crossplane
- **Inode allocation**: Consider increasing inode count on this VM in future (2.4M is very low)
- **Raft snapshots**: Will automatically compact `raft.db` preventing unbounded growth
- **Audit logs**: stdout ensures logs don't create files that consume inodes

---

**Command Reference**:

```bash
# Quick status check
export VAULT_ADDR=https://bao.hnatekmar.xyz
export VAULT_TOKEN="s.1Jl5g42IPYUota1GGAyhEJ0E"
bao status

# Monitor sync
argocd app get openbao --watch

# Check logs
kubectl logs -n openbao-system openbao-0 --tail=100 --follow

# Verify inodes
ssh root@static.26.154.224.46.clients.your-server.de "df -i / && df -h /"
```
