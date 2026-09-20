# Keycloak Configuration Guide

This document describes how to configure Keycloak resources using Crossplane. All Keycloak resources use the `keycloak.crossplane.io` provider.

## Resource Types

### Group (group.keycloak.crossplane.io/v1alpha1)

Defines a Keycloak group for organizing users. Groups are used to assign roles and permissions.

**Example**: `crossplane/config/keycloak/groups/hnatekmarorg-base.yaml`

```yaml
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Group
metadata:
  name: hnatekmarorg-base
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: hnatekmarorg-base
    realmId: master
```

**Key Fields**:
- `providerConfigRef.name`: Reference to the Keycloak provider config
- `forProvider.name`: Group name in Keycloak
- `forProvider.realmId`: Keycloak realm (typically `master`)

### Role (role.keycloak.crossplane.io/v1alpha1)

Defines a realm role in Keycloak. Roles are assigned to users via group mappings.

**Example**: `crossplane/config/keycloak/roles/hnatekmarorg-base-realm.yaml`

```yaml
apiVersion: role.keycloak.crossplane.io/v1alpha1
kind: Role
metadata:
  name: hnatekmarorg-base-realm-role
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    name: hnatekmarorg-base
    realmId: master
    description: "Base role for hnatekmarorg SSH certificate access"
```

**Key Fields**:
- `forProvider.name`: Role name in Keycloak
- `forProvider.realmId`: Keycloak realm
- `forProvider.description`: Human-readable description

### Client (openidclient.keycloak.crossplane.io/v1alpha1)

Defines an OIDC client for external applications to authenticate with Keycloak.

**Example**: `crossplane/config/keycloak/clients/bao-client.yaml`

```yaml
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: Client
metadata:
  name: bao-hnatekmar-xyz
spec:
  writeConnectionSecretToRef:
    namespace: crossplane-system
    name: bao-hnatekmar-xyz
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    accessType: CONFIDENTIAL
    clientId: bao-hnatekmar-xyz
    standardFlowEnabled: true
    enabled: true
    realmId: master
    webOrigins:
      - https://bao.hnatekmar.xyz
    validRedirectUris:
      - https://bao.hnatekmar.xyz/ui/vault/auth/oidc/oidc/callback
      - http://localhost:8250/oidc/callback
```

**Client Types**:

1. **CONFIDENTIAL**: For server-to-server communication
   - Requires client secret
   - Use this for backend services like OpenBao

2. **PUBLIC**: For applications like CLIs or SPAs
   - No client secret required
   - Enable `directAccessGrantsEnabled: true` for CLI support
   - Set `pkceCodeChallengeMethod: S256` for PKCE support

**Key Fields**:
- `accessType`: `CONFIDENTIAL` or `PUBLIC`
- `clientId`: Client identifier
- `standardFlowEnabled`: Enable authorization code flow
- `directAccessGrantsEnabled`: Enable direct grant (resource owner password) for CLI tools
- `validRedirectUris`: List of allowed callback URLs
- `webOrigins`: List of allowed CORS origins
- `pkceCodeChallengeMethod`: `S256` for PKCE support (public clients)

### Group Roles (group.keycloak.crossplane.io/v1alpha1)

Maps Keycloak groups to realm roles, automatically assigning roles to group members.

**Example**: `crossplane/config/keycloak/roles/hnatekmarorg-base-mapping.yaml`

```yaml
apiVersion: group.keycloak.crossplane.io/v1alpha1
kind: Roles
metadata:
  name: hnatekmarorg-base-roles
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    groupIdRef:
      name: hnatekmarorg-base
    realmId: master
    roleIdsRefs:
      - name: hnatekmarorg-base-role
    exhaustive: true
```

**Key Fields**:
- `groupIdRef.name`: Reference to the Group resource
- `roleIdsRefs`: List of roles to assign to group members
- `exhaustive`: If `true`, roles not listed will be removed from the group

- **Wave 4**: Group-to-role mappings

### Client Default Scopes Configuration

When creating OIDC clients for OpenBao/Vault or similar services that require JWT tokens with specific claims, always configure default scopes to ensure required claims are included:

```yaml
apiVersion: openidclient.keycloak.crossplane.io/v1alpha1
kind: ClientDefaultScopes
metadata:
  name: <client>-default-scopes
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  deletionPolicy: Delete
  providerConfigRef:
    name: sso-hnatekmar-xyz
  forProvider:
    clientIdRef:
      name: <client>
    realmId: master
    defaultScopes:
      # Required: email claim for user identification
      - email
      # Required: microprofile-jwt scope for groups in token
      - microprofile-jwt
      # Optional: custom groups scope if additional group mapping is needed
      - <custom-groups-scope>
```

**Required Default Scopes**:

1. **`email`**: Standard OpenID Connect scope that adds the `email` claim to tokens. Required for OpenBao authentication which uses `userClaim: email`.

2. **`microprofile-jwt`**: Keycloak's built-in scope for MicroProfile JWT propagation. Includes groups in the token, required for JWT-based authorization.

**Common Issues**:

- **`claim "email" not found in token`**: The client is missing the `email` default scope. Add `email` to the `ClientDefaultScopes` resource.
- **Groups not in token**: Ensure `microprofile-jwt` is included in default scopes, or create a custom protocol mapper for groups.

### Machine clients (client credentials)

A client no human drives — an agent, a controller, a scheduled job — cannot run the
authorization-code flow, and it should not be given a password to borrow. Declare it as a service
account instead: `CONFIDENTIAL`, `serviceAccountsEnabled: true`, and both `standardFlowEnabled` and
`directAccessGrantsEnabled` false, so `client_credentials` is the only grant it can use.

**Example**: `crossplane/config/keycloak/clients/kubectl-agent-client.yaml`

Four things are needed before such a client can reach a Kubernetes API server, and none of them are
obvious:

| Piece | Why |
|---|---|
| A `ClientServiceAccountRealmRole` per cluster-access role | RBAC binds realm roles, and a service account holds none by default. |
| An `oidc-audience-mapper` carrying the cluster's client id | Clusters validate `audiences = [oidc_client_id]`; a client-credentials token is issued with `aud: account` and is rejected with a bare 401. |
| An `oidc-hardcoded-claim-mapper` for `email` | The Kubernetes username is mapped from `email` and a service account has no email, so the claim would simply be absent. Do **not** reach for the `email` scope here: it can also emit `email_verified: false`, which the API server rejects (`oidc: email not verified`). |
| An `oidc-usermodel-realm-role-mapper` with `claim.name: groups` | This is the claim RBAC actually binds, and `microprofile-jwt` — enough for a human client — produces **no** `groups` claim at all for a service account. Measured: the roles arrive only under `realm_access.roles`, so the API server sees `[system:authenticated]` and forbids everything while authentication itself succeeds. |

Deliberately absent, for the same reason each row above exists:

- **`microprofile-jwt` and the `email` scope.** Each would be a second, differently-behaving
  producer of a claim this client already names explicitly. One producer per claim is what makes the
  token predictable from the manifest alone.
- **`offline_access`** (and therefore any `ClientOptionalScopes`): `client_credentials` never returns
  a refresh token.
- **`webOrigins` and `validRedirectUris`**: there is no redirect to come back to.

The client's connection secret (`attribute.client_id`, `attribute.client_secret`) lands in the
namespace named by `writeConnectionSecretToRef`. The caller mints a short-lived token per use —
the realm issues this identity a 60s access token, so caching one buys nothing:

```bash
curl -s -X POST https://sso.hnatekmar.xyz/realms/master/protocol/openid-connect/token \
  -d grant_type=client_credentials \
  -d client_id=... -d client_secret=... | jq -r .access_token
```

### Management clients (a cluster maintaining its own realm objects)

A machine client can also be an ADMINISTRATOR of a slice of the realm. That is how the on-prem clusters
create the clients their services consume — see `crossplane/config/keycloak/clients/crossplane-prod-client.yaml`
and its `dev` twin:

| Piece | Why |
|---|---|
| `serviceAccountsEnabled: true`, `standardFlow`/`directAccessGrants` false | Only `client_credentials` is usable: no browser, no password to borrow. |
| `ClientServiceAccountRole` with `clientIdRef` → a Client MR for the realm's admin client, `role: manage-clients` | Create/update clients, their protocol mappers and scope assignments. This IS the job, and it composites `view-clients`, so reads come with it. The admin client is `<realm>-realm` in the master realm and `realm-management` anywhere else — see the two traps below. |
| `ClientServiceAccountRole` with `role: view-realm` | Read-only realm metadata. Not needed to write a client, but the provider reads realm state while reconciling and a 403 there reads like a bad secret rather than a missing grant. |
| One client **per on-prem cluster** | Revocation is per cluster, and Keycloak's admin events record the acting client, so "which cluster created this?" answers itself. |

What such a client deliberately cannot do: manage users, groups, identity providers, realm settings, or
grant a service account a realm role (that needs `manage-users`). A service that must authenticate to a
Kubernetes API server gets its realm roles granted here, in the hub, by a hub-owned manifest — the way
`kubectl-agent-client.yaml` does it. Keeping those two jobs in different identities is what stops an
on-prem compromise from minting cluster access for itself.

Its credential is the same document shape as any other provider config. Only `client_id` and `url` are
required; the presence of `client_secret` with `username`/`password` absent is what selects the
client-credentials grant (provider-keycloak v2.17.0, `internal/clients/keycloak.go`):

```json
{
  "url": "https://sso.hnatekmar.xyz",
  "client_id": "crossplane-prod-hnatekmar-xyz",
  "client_secret": "...",
  "realm": "master"
}
```

That document crosses to the on-prem vault **once** — `devops-cluster`'s
`./scripts/seed-vault.sh keycloak-writer <cluster>` — and the on-prem cluster's own Crossplane reads it with
ESO from `secret/<cluster>/keycloak-writer`. Because `writeConnectionSecretToRef` writes into the cluster
where the provider runs, the client secret lands locally: there is no WAN→LAN push to maintain, and the hub
needs no route into the LAN.

**Two traps, both measured — and the second one invalidated the first fix.**

*One: the field carries a UUID, not a name.* `ClientServiceAccountRole.clientId` is NOT a clientId. The
provider's generated schema attaches `extractor=common.UUIDExtractor()` to it, because the admin API's
role-mapping endpoint takes the role-providing client's **internal UUID**:

```
POST /admin/realms/{realm}/users/{service-account-id}/role-mappings/clients/{client-uuid}
```

So a bare `clientId: master-realm` puts a string where a UUID belongs, every other field in the object
resolves, and the grant fails at runtime with

```
404 Not Found. Response body: {"error":"Client not found"}
```

leaving the managed resource `Ready: False` while the *client* objects themselves reconcile fine — which is
what makes a URL-shape bug look like a permissions problem. Remedy: `clientIdRef` against a Client MR for the
role-providing client; the reference resolves that MR's observed `status.atProvider.id`.

*Two: the admin client has a different NAME in the master realm.* Keycloak's docs state it plainly: "if you
are in the master realm, select the one with NAME-realm, where NAME is the name of the realm". So the master
realm's admin client is **`master-realm`**, and `realm-management` exists only in non-master realms. Naming
the wrong one fails *differently*, in a way that reads like a permission error rather than a typo:

```
async create failed: [{0 openid client with name realm-management does not exist  []}]
```

That message has exactly one source — `GetOpenidClientByClientId` receiving a 200 with an **empty list**.
Because a client that exists but is wrongly addressed and a client that does not exist at all both produce a
404 from the admin API, it is worth telling the two traps apart before changing anything. To check which
client a realm actually has, probe the authorize endpoint and **include a known-nonexistent client as a
control**:

| probe | answer |
|---|---|
| `client_id=definitely-not-a-real-client` | `Client not found` |
| `client_id=master-realm` | `403` — real, and refusing a browser flow (it is bearer-only) |
| `client_id=realm-management` in the master realm | `Client not found` — identical to the made-up name |

The token endpoint is useless for this: an unknown client and a bad secret both answer
`invalid_client: Invalid client or Invalid client credentials`, so a probe without the nonexistent control
proves nothing (and once concluded, wrongly, that this client existed).

*The adopted MR, OBSERVED rather than imported:*

```yaml
metadata:
  annotations:
    crossplane.io/external-name: <the client's uuid>   # admin console URL — an identifier, not a secret
spec:
  deletionPolicy: Orphan
  managementPolicies: ["Observe"]      # no Create/Update/Delete: nothing can write to this client
  forProvider:
    realmId: master
    clientId: master-realm
    accessType: BEARER-ONLY            # declared for the reader; never applied
```

Terraform's `import` attribute is the obvious adoption route and the wrong one for this client: the
provider's import branch is `GetOpenidClientByClientId` → `mergo.Merge` → **`UpdateOpenidClient`**, so it
WRITES the client — and the one attribute we could declare (`accessType`) is unverifiable, because
`master-realm` is bearer-only and no existence probe distinguishes that from confidential. Observe-only
removes the question, and it also means the CEL rule requiring `accessType` on any client object that may
Create or Update (`!('*' in policy || 'Create' in policy || 'Update' in policy) || has(accessType)`) does
not apply.

The durable version of this is a composition rather than a pinned id: `function-keycloak-builtin-objects`
enumerates a realm's builtin clients and roles and composes observe-only MRs carrying their UUIDs as
external names. On Crossplane 1.20 it additionally needs a later pipeline step to stamp
`metadata.namespace` on what it composes — nothing defaults a composed resource's namespace (measured: a
cluster-scoped composite, and equally a claim, both fail with "an empty namespace may not be set when a
resource name is provided"). That is a change worth making deliberately, not inside a fix.
