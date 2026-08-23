# GitHub Actions self-hosted runner (Algovectra)

A **plain Kubernetes Deployment** (`replicas: 1`) running the official
`ghcr.io/actions/actions-runner` image as an org-level runner for **Algovectra**.
Deliberately *not* actions-runner-controller (ARC) — no operator, no CRDs, no
autoscaling. On a single node with one persistent runner, ARC's machinery is
pure overhead and was the source of the instability we hit before.

- **Org**: `Algovectra` (org-level registration)
- **Label**: `gha-runner-scale-set-algovectra` — drop-in for workflows that
  already target the old ARC runner group:
  ```yaml
  runs-on: [self-hosted, gha-runner-scale-set-algovectra]
  ```
  (`self-hosted` and `Linux` are added automatically.)
- **Scope**: shell/lint/test/deploy CI **only**. No nested containers — this
  runner cannot run `container:` jobs, `docker build`, or `docker run`. Route
  those to the host DIND builder with a different label.

## Files

| File | Purpose |
|------|---------|
| `argocd/gh-runner.yaml` | Deployment (1 replica) + ServiceAccount (zero RBAC) |
| `argocd/gh-runner/resources.yaml` | `runner` namespace + `gh-runner` PVC (registration state) |

Picked up automatically by the `init` ArgoCD Application (recurses `argocd/`).

## Security model (by construction)

- **No host `docker.sock`, no host paths, not privileged, no nested runtime.**
  The runner literally cannot spawn containers — enforces the "no nested
  containers" requirement at the pod level rather than trusting config.
- **Non-root**: `runAsUser: 1001` (the image's `runner` user), `runAsNonRoot`,
  `allowPrivilegeEscalation: false`, all capabilities dropped,
  `readOnlyRootFilesystem` (with an `emptyDir` at `/tmp` for transient files).
- **Dedicated SA, zero RBAC, `automountServiceAccountToken: false`** — a runner
  needs no Kubernetes API access; it only long-polls GitHub. This pod cannot
  touch the host DIND builder, the node, or other pods beyond normal networking.
- **Isolation from DIND**: the host DIND builder runs under a separate Linux
  account; this pod is a separate k8s workload with no shared socket or path.
  A compromised runner cannot reach the builder or the host.

### Image layout (why the init container exists)

The `ghcr.io/actions/actions-runner` image ships `run.sh`, `config.sh`, `bin/`,
and `externals/` in `/home/runner` (WORKDIR, user `runner` = UID/GID 1001, no
ENTRYPOINT). The registration credentials (`.runner`, `.credentials`) and job
workspaces (`_work`, `_diag`) are written to that same directory. So the PVC
must be mounted at `/home/runner` to persist registration across pod regens —
but an empty PVC there would shadow the image's binaries (the original
`stat ./run.sh: no such file or directory` crash). The `seed-home` init
container fixes this: on every boot it `cp -a --no-clobber` the image's
`/home/runner` into the PVC, seeding the binaries on first boot while
preserving an existing `.runner`/`.credentials` on subsequent boots.

## One-time registration

Registration is **manual, once**. The GitHub registration token is short-lived
(~1h) and single-use, so it is fetched ad-hoc (never committed, never in OpenBao).
After the initial `config.sh`, the runner holds long-lived credentials on the
PVC and re-registers never — it just runs `run.sh` on every pod start.

### Prerequisites

A PAT with `admin:org` scope on `Algovectra` (to call the registration-token
endpoint). Create a throwaway one at
https://github.com/settings/tokens — delete after registering.

### Host sysctl (required — inotify)

The .NET runner opens many `inotify` watchers and will crash with
`fsnotify watcher: too many open files` on the kernel default
`fs.inotify.max_user_instances=128`. This is a **host-level** limit (inotify
instances are global, not namespaced — a pod `securityContext` cannot raise it),
so set it on the Hetzner node:

```bash
# persist across reboots
echo 'fs.inotify.max_user_instances=1024' | sudo tee /etc/sysctl.d/99-inotify.conf
sudo sysctl -p /etc/sysctl.d/99-inotify.conf
# verify
sysctl fs.inotify.max_user_instances   # -> 1024
```

(`max_user_watches` is already ~256k and fine; only `max_user_instances` is the
constraint.) Applies to all runner pods on the node.

### 1. Let ArgoCD create the namespace + PVC + pod

Wait for the `gh-runner` Deployment to exist (it will `CrashLoopBackOff` until
registered — expected, since `run.sh` finds no `.runner` file):

```bash
kubectl -n runner get pvc gh-runner    # Bound
kubectl -n runner get pod -l app.kubernetes.io/name=gh-runner
```

### 2. Fetch a registration token

```bash
PAT=ghp_***             # admin:org on Algovectra
ORG=Algovectra
TOKEN=$(curl -s -X POST \
  -H "Authorization: token $PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$ORG/actions/runners/registration-token" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
echo "$TOKEN"           # ~1h lifetime, single use
```

### 3. Register into the PVC (one-shot exec)

```bash
POD=$(kubectl -n runner get pod -l app.kubernetes.io/name=gh-runner -o name | head -1)

kubectl -n runner exec "$POD" -- ./config.sh \
  --url "https://github.com/$ORG" \
  --token "$TOKEN" \
  --labels "gha-runner-scale-set-algovectra" \
  --runnergroup "default" \
  --unattended --replace
```

- `--labels` is the value workflows target with `runs-on:`. (`self-hosted` and
  the OS are auto-added; do not list them.)
- `--unattended` = non-interactive; `--replace` = safe to re-run if a stale
  half-registration exists on the PVC.
- Credentials are written under `/actions-runner` (the PVC). The currently
  running pod is mid-CrashLoop; either delete it so the Deployment recreates
  with a registered home, or just `./run.sh` in the same exec to verify, then
  delete the pod:

```bash
kubectl -n runner delete pod "$POD"   # Deployment recreates; now runs run.sh on a registered PVC
```

### 4. Verify

```bash
# Pod goes Running and stays up
kubectl -n runner get pod -l app.kubernetes.io/name=gh-runner

# GitHub sees it: https://github.com/organizations/Algovectra/settings/actions
#   → Runners → a runner labelled gha-runner-scale-set-algovectra, Idle
```

Trigger any workflow with `runs-on: [self-hosted, gha-runner-scale-set-algovectra]`.

## Maintenance

- **Restart / reboot**: nothing to do. The pod re-runs `run.sh` from the PVC;
  credentials persist. `Recreate` strategy means a restart never runs two pods.
- **Move/recreate the runner**: delete it in the GitHub UI (Settings → Actions →
  Runners), wipe the PVC (`kubectl -n runner delete pvc gh-runner`), let ArgoCD
  recreate it, then re-run step 3 with a fresh token.
- **Upgrade the runner image**: the image tag is `latest` (upstream-published).
  Bump by deleting the pod; the new image reuses the same registration. To pin,
  set an explicit tag in `argocd/gh-runner.yaml`.
- **Label change**: edit `argocd/gh-runner.yaml`? No — labels are set at
  registration, not in the manifest. Re-register (step 3) with new `--labels`.
