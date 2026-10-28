# Kubernetes access over SSO — kubeconfig, RBAC and Keycloak

How a human gets `kubectl` access to this cluster without a client certificate: they log in to
Keycloak, and Kubernetes decides what they may do from the roles they hold there.

The point is that the kubeconfig holds **no credential** — only the API server address, its public
CA, the issuer URL and a public client id. Nothing in it grants anything, so it can be copied,
committed or emailed without leaking access. Access is revoked in Keycloak, not by collecting files.

```
kubectl ──exec──► kubelogin ──auth code + PKCE──► Keycloak (sso.hnatekmar.xyz, realm master)
                     │                                    │
                     │        id_token: email, groups     │  realm roles
                     ▼                                    ▼
              kube-apiserver ──groups claim + sso: prefix──► RBAC (ClusterRoleBinding)
```

## The pieces and where they live

| Piece | Where | Managed by |
|-------|-------|------------|
| OIDC client `kubectl-hnatekmar-xyz` | `crossplane/config/keycloak/clients/kubectl-client.yaml` | Crossplane, in Git |
| Realm roles `k8s-{infra,dev}-{viewer,admin}` | `crossplane/config/keycloak/roles/k8s-*.yaml` | Crossplane, in Git |
| Role → group assignment | `crossplane/config/keycloak/roles/hnatekmarorg-admin-realm-mapping.yaml` | Crossplane, in Git |
| API server OIDC flags | `/etc/rancher/k3s/config.yaml` on each server node | **out of band — see below** |
| ClusterRoleBindings | `rbac/cluster-access.yaml` (applied by `argocd/rbac.yaml`) | ArgoCD, in Git |
| The kubeconfig itself | generated per user | `scripts/kubeconfig/sso-kubeconfig.sh` |

## 1. Keycloak

The client is **PUBLIC** and uses PKCE (S256) instead of a secret, because kubelogin is a native
CLI: there is no secret to leak or rotate. The password grant is deliberately disabled — it would
bypass the GitHub identity providers and MFA.

Two properties matter for Kubernetes and are easy to break:

- `fullScopeAllowed: true` and the `microprofile-jwt` default scope are what put the user's realm
  roles into the token's `groups` claim.
- The redirect URIs are `http://localhost:8000` and `http://localhost:18000` — kubelogin's default
  port and its fallback. Keycloak matches them exactly; a different port fails with
  *Invalid parameter: redirect_uri*.

**Granting access** is assigning a realm role. `hnatekmarorg-admin` already carries `k8s-infra-admin`.
To give someone read-only access, assign them `k8s-infra-viewer` directly in the Keycloak admin
console — or add the role to a group's mapping. If you use a group mapping, add the role to the
**existing** `Roles` resource for that group: those resources are `exhaustive: true`, so a second
resource for the same group would keep deleting the first one's grant.

A user with no `k8s-*` realm role can still authenticate and gets a token with no groups — every
request is then Forbidden (403), which is the intended outcome, not a bug.

## 2. API server (out of band: k3s)

The API server must be told to trust the issuer. This is the one piece that is not in Git, because
it is a static-pod argument rather than a Kubernetes object. On every server node, in
`/etc/rancher/k3s/config.yaml`:

```yaml
kube-apiserver-arg:
  - oidc-issuer-url=https://sso.hnatekmar.xyz/realms/master
  - oidc-client-id=kubectl-hnatekmar-xyz
  - oidc-username-claim=email
  - oidc-groups-claim=groups
  - oidc-username-prefix=sso:
  - oidc-groups-prefix=sso:
```

Then `systemctl restart k3s` on each node (one at a time on an HA control plane) and verify:

```bash
./scripts/kubeconfig/verify-oidc.sh --kubeconfig ~/.kube/hetzner
```

Why each flag:

- **issuer / client-id** must match the kubeconfig byte for byte. A trailing slash difference makes
  every login fail with the same bare 401.
- **groups-claim `groups`** is where the realm roles arrive.
- **the `sso:` prefixes** are not cosmetic. Without a groups prefix, a Keycloak role named
  `system:masters` would land in the token verbatim and Kubernetes would honour it as cluster-admin.
  The prefix namespaces everything Keycloak can say into `sso:*`.

The API **server**, not your laptop, fetches the discovery document and JWKS. If the cluster cannot
reach `sso.hnatekmar.xyz`, logins fail even though your browser can. Its certificate is public
Let's Encrypt, so the host trust store is normally enough; a private CA needs `oidc-ca-file` added
to the same argument list.

Note on the username claim: Kubernetes rejects a token whose `email_verified` is `false`
(*oidc: email not verified*). Keycloak sets that flag from the identity provider, so a user whose
GitHub email is unverified cannot log in until it is verified in Keycloak.

## 3. Kubernetes RBAC

`rbac/cluster-access.yaml` is applied by the `cluster-access` Application at sync-wave -1 — ahead of
every component, because a binding depends on nothing and is the object that lets a human repair
everything else. Mounted behind a failing wave it would leave a cluster that authenticates its
administrator and authorises nothing.

**This cluster is the `infra` class.** It hosts Keycloak, OpenBao and ArgoCD, so it must keep
working. Only the infra pair is bound:

| Keycloak realm role (in token) | Kubernetes group after prefix | ClusterRole |
|---|---|---|
| `k8s-infra-viewer` | `sso:k8s-infra-viewer` | `view` (built-in; cannot read Secrets) |
| `k8s-infra-admin` | `sso:k8s-infra-admin` | `cluster-admin` (built-in) |

`k8s-dev-admin` — the role that is meant to let someone break a sandbox freely — grants **nothing**
here. That is the point of the two-class model, and it is structural: the dev bindings are simply
not in this cluster's manifests.

Both tiers use built-in ClusterRoles. There is no custom role to audit or to drift.

## 4. Generate the kubeconfig

From a kubeconfig that can already reach the cluster (the admin one used at bootstrap):

```bash
./scripts/kubeconfig/sso-kubeconfig.sh --from ~/.kube/hetzner
# writes ~/.kube/<cluster>-sso.yaml
```

It copies only the server and CA, and wires the `exec` block to kubelogin. The output is validated
before it is published: it must parse, it must resolve to the cluster, it must carry no
certificate/token, and its user must be the kubelogin exec block — otherwise nothing is written.

Useful flags: `--context` to pick the source context, `--output`, `--issuer`, `--client-id`,
`--extra-scope` (replaces the default `offline_access`), `--stdout`, `--force`.

`offline_access` is the default extra scope on purpose: it yields a refresh token, so kubelogin
renews silently instead of sending the user to the browser every few minutes.

The machine that *uses* the kubeconfig needs kubelogin:

```bash
brew install int128/kubelogin/kubelogin
# or: go install github.com/int128/kubelogin@latest
```

## 5. Log in and verify

```bash
kubectl --kubeconfig ~/.kube/hetzner-sso.yaml auth whoami
```

Expected:

```
ATTRIBUTE   VALUE
Username    sso:you@example.com
Groups      [sso:k8s-infra-admin system:authenticated]
```

`auth whoami` prints what the API server parsed from the token — username and groups — which is
exactly the input to RBAC. If the `sso:k8s-…` group is missing, stop there: no amount of RBAC will
grant anything.

```bash
kubectl --kubeconfig ~/.kube/hetzner-sso.yaml auth can-i --list   # effective permissions
./scripts/kubeconfig/verify-oidc.sh --kubeconfig ~/.kube/hetzner \
    --sso-kubeconfig ~/.kube/hetzner-sso.yaml                      # end to end
```

## 6. Day-2

- **Revoke** by removing the realm role (or the group membership) in Keycloak. Nothing to collect
  from the user; their next request fails, and the token they hold expires within the realm's
  access-token lifespan (5 minutes by default).
- **Token cache** lives in `~/.kube/cache/oidc-login`; `kubelogin clean` (or
  `kubectl oidc-login clean` when using the plugin) clears it.
- **Lost laptop** is not an incident for this cluster: the kubeconfig has no credential in it.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `401 Unauthorized`, no detail | `oidc-issuer-url` mismatch (often a trailing slash), API server cannot reach the issuer, or its CA is untrusted |
| `oidc: id token issued by a different provider` / audience error | kubeconfig `--oidc-client-id` differs from the API server's `oidc-client-id` |
| `oidc: email not verified` | user's email is unverified in Keycloak |
| Browser: `Invalid parameter: redirect_uri` | kubelogin is listening on a port the client does not list (8000/18000) |
| Login works, then `403 Forbidden` | authenticated but no binding: check `auth whoami` for a `sso:k8s-*` group |
| `auth whoami` shows no `sso:` group | user holds no `k8s-*` realm role, or the `groups` claim is missing (client lost `microprofile-jwt`) |
| Groups present but unprefixed | `oidc-groups-prefix=sso:` missing from the API server |
| `sso:k8s-dev-admin` holder gets 403 here | correct — this is an infra cluster |

401 vs 403 is the first fork: 401 is authentication (issuer, client id, signature, email
verification); 403 is authorisation (roles, prefix, binding).
