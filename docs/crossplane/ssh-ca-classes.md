# SSH CA classes (infra / dev)

Status: **prototype** — manifests validated against a throwaway OpenBao, mechanics proven
locally (see [Verification](#verification)). Nothing has been applied to a live host or to
the live OpenBao yet; adoption is the rollout section below.

## The model, in one paragraph

Two SSH CAs, one per class. An **infra** host trusts the infra CA and nothing else; a
**dev** host trusts the dev CA and nothing else. A certificate is therefore *scoped by
construction*: a dev-class certificate does not merely lack permission on an infra host,
it fails to verify there. This is the same two-axis idea as
`devops-cluster/charts/cluster-base/templates/rbac/cluster-access.yaml` (`clusterClass:
dev|infra`), where a cluster emits only its own class's bindings — there the class is a
chart input, here it is the CA that signed the key.

| Axis | What it means | Where it lives |
|---|---|---|
| **class** — `infra` / `dev` | which population of machines the credential belongs to | **the CA** (`hnatekmarorg-ssh-infra` / `hnatekmarorg-ssh-dev`) |
| **tier** — `admin` (later: `viewer`) | what the credential may do | **the certificate's principal**, gated by sshd's `AuthorizedPrincipalsFile` |

Only the `admin` tier exists in this iteration (as agreed: *"this time only admin role"*).
The tier axis is nonetheless in place, because it is what makes the next one additive
rather than a re-key: adding `viewer` means adding a signing role with principal `viewer`
and *not* listing it in a host's principals file.

## Why two CAs rather than two roles on one CA

One CA with two `admin-*` roles would leave enforcement to per-host sshd configuration: a
host that listed both principals (or forgot `AuthorizedPrincipalsFile` entirely) would
silently merge the classes. Two CAs make the isolation structural — the equivalent of the
"an infra cluster literally cannot emit the dev bindings" property, so the failure mode
fails closed:

| Setup | A dev cert on an infra host | Failure mode when a host is misconfigured |
|---|---|---|
| one CA, two roles | refused **if** the host's principals file is right | **fails open** — accepts the other class |
| two CAs (this) | not trusted by any configuration of that host | fails closed — the key does not verify |

Case 7 in `scripts/ssh-ca/test-class-separation.sh` demonstrates the merged state, so the
difference is observable rather than asserted.

## Pieces

| File | What it is |
|---|---|
| `hnatekmarorg/ssh/classes/{infra,dev}/mount.yaml` | the class's SSH secrets engine |
| `hnatekmarorg/ssh/classes/{infra,dev}/ca.yaml` | the class's CA key (generated in OpenBao, never in git) |
| `hnatekmarorg/ssh/classes/{infra,dev}/role-admin.yaml` | the `admin` signing role: user certs, principal `admin` |
| `hnatekmarorg/policies/ssh-class-{infra,dev}.yaml` | who may sign which class, plus read of the class trust anchor |
| `scripts/ssh-ca/enroll.sh` | runs on a host: `trust` / `issue` / `verify` / `status` |
| `scripts/ssh-ca/test-class-separation.sh` | proves the sshd contract without OpenBao (9 cases) |
| `scripts/ssh-ca/test-openbao-contract.sh` | proves the OpenBao contract on a throwaway dev server (16 checks) |

Class names are validated, never guessed: an absent or misspelled `--class` is a hard
error, exactly as `clusterClass` refuses to default. Guessing wrong here would mean a host
trusting the wrong population's CA.

## The contract

**The certificate** (identical in shape for every class — the class is the CA):

```
Type: ssh-ed25519-cert-v01@openssh.com user certificate
Key ID: "infra:balteus"                      <- class:hostname, audit label (allow_user_key_ids)
Principals: admin                            <- tier (allowed_users constrains this to exactly `admin`)
Valid: 24h (max 168h)
Critical Options: source-address 172.16.0.0/20,…   <- the estate's nets
Extensions: permit-pty, permit-port-forwarding, permit-X11-forwarding
```

**The host** (`enroll.sh --class <class> trust`):

```
# /etc/ssh/sshd_config.d/10-openbao-<class>-ca.conf
TrustedUserCAKeys /etc/ssh/ssh_ca_<class>.pub      <- the whole class decision, one line
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```

`/etc/ssh/auth_principals/<user>` contains `admin`. The file is the same on every host;
only the `TrustedUserCAKeys` line differs between an infra and a dev host — the diff
between the two classes is one line, and it is the line that matters.

Two behaviours worth knowing because they are how the contract holds:

- The login user is `root` (`ssh root@host`); the certificate's principal is `admin`. sshd
  accepts it because `AuthorizedPrincipalsFile` for `root` lists `admin`. Without that file
  the login is refused (case 8) — the gate fails closed rather than falling back to "the CA
  signed it, so let it in".
- The `admin` role sets `default_user: admin`, so a caller who requests no principal still
  gets `principals = [admin]`. There is no second certificate shape that would skip the gate.

**The machine's own identity** (`enroll.sh --class <class> issue`) is the same mechanism
from the other side: key + certificate in `/etc/ssh/openbao-client/`, wired into
`/etc/ssh/ssh_config.d/`, so the host presents its class certificate when it SSHs out.
`IdentitiesOnly` is deliberately *not* set there — on an existing host that would break
every other key it uses. Setting it is the hardening step once static keys are gone.

## Enrollment

```bash
# an infra host: balteus, TrueNAS, the GitHub runner, keepers
scripts/ssh-ca/enroll.sh --class infra trust    # trust the infra CA, install sshd config
scripts/ssh-ca/enroll.sh --class infra issue    # mint + install this host's admin cert
scripts/ssh-ca/enroll.sh --class infra verify   # what is installed, and what sshd resolves

# a developer/sandbox host: kubernetes-sandbox (VM 133)
scripts/ssh-ca/enroll.sh --class dev trust
scripts/ssh-ca/enroll.sh --class dev issue
scripts/ssh-ca/enroll.sh --class dev verify
```

`verify` fails if both classes' CAs are trusted by the same host — that state is the
silent class merge, and a host should never be in it.

Credentials for `trust`/`issue`: a class-scoped token (policy
`hnatekmarorg-ssh-class-<class>`) for a machine; the human admin token works too but is not
what a server should carry. `trust` needs only `read` on `<mount>/config/ca`, which returns
the **public** key.

## Verification

Both suites are hermetic and were run as part of this prototype.

**`scripts/ssh-ca/test-class-separation.sh`** — two local CAs, four throwaway sshds on
127.0.0.1, nothing under `/etc/ssh` touched. Probes authentication only (`ssh -N` + timeout;
124 = accepted, 255 = refused), so the result cannot be confounded by hosts whose SELinux
policy prevents a test sshd from exec'ing a shell:

```
1 infra cert  -> infra host                      accepted
2 infra cert  -> dev host                        refused
3 dev   cert  -> dev host                        accepted
4 dev   cert  -> infra host                      refused
5 bare key, no cert -> infra host                refused
6 principal 'viewer' -> infra host               refused
7 infra cert -> host trusting BOTH CAs           accepted   <- the merged state, for contrast
8 infra cert -> host with no principals file     refused    <- fails closed
9 infra cert pinned to 10.0.0.0/8 from 127.0.0.1 refused    <- source-address enforced by sshd
10 cert principal 'root' -> host with no principals file  accepted  <- sshd's direct-match path
11 cert principal 'admin' -> host with no principals file refused   <- why the tier is not a login name
```

**`scripts/ssh-ca/test-openbao-contract.sh`** — a `bao server -dev` (in-memory, no live
infra): two independent class CAs, the role fields round-trip, the issued certificate
carries `principals = admin`, the key id, a 24h window and the `source-address` pin, a
request for `valid_principals = root` is refused, and a token holding one class's policy can
sign its own class, read its own trust anchor, and is refused on the other class.

## Findings worth acting on outside this prototype

1. **`cidrList` does nothing on these roles — including the ones already in this repo.**
   The OpenBao API documents `cidr_list` as *"Not applicable for CA type"* (it belongs to
   OTP-type roles), and a dev-server test confirms it: a CA role with `cidr_list` set issues
   a certificate with `Critical Options: (none)`. So `ssh/role.yaml` and `ssh/infra-role.yaml`
   (and `algovectra/ssh/role.yaml`) carry dead config, and the overhaul plan's Phase 2 step 1
   (*"tighten cidrList 0.0.0.0/0 → …"*) would not have changed behaviour. The class roles
   therefore use `defaultCriticalOptions.source-address` instead — verified to land on the
   certificate and enforced by sshd (case 9).
   Residual: a caller holding *sign* rights can override `critical_options`, so this bounds a
   leaked certificate, not a leaked sign token. The class gate cannot be overridden this way.
2. **`key_id` is refused unless the role sets `allow_user_key_ids: true`** — the engine
   answers `setting key_id is not allowed by role` otherwise. Hence the field on both roles:
   it is what makes `ssh-keygen -L` and the sshd log say *which machine, which class*.
3. **`default_user` is the principal — and it must be a member of `allowed_users`.**
   OpenBao validates it: with `allowed_users: admin`, a role whose `default_user` is `root`
   refuses even a principal-less sign (`root is not a valid value for valid_principals`), so
   `default_user: root` here is a *broken* default, not a looser one. The class roles set both
   fields to `admin`, and `ssh root@host` is unaffected — the login user comes from the client,
   and the principals file is what admits `admin` for it.
   **The tier deliberately is not a login name.** sshd matches a certificate principal against
   the target login *directly*, with no `AuthorizedPrincipalsFile` involved. Measured
   (cases 10/11): on a host with `TrustedUserCAKeys` and no principals file, a
   `principals=[root]` certificate is accepted for `root` while the tier-gated `admin` one is
   refused. A tier named `root` would therefore work by default on any unconfigured host —
   silently skipping the gate — whereas `admin` makes such a host refuse everything until the
   principals file is in place. Fails closed, by naming.
4. **Debian's `sshd_config` has no `sshd_config.d` include by default** (Proxmox hosts are
   Debian). `enroll.sh` detects this, inserts the include, and keeps `sshd_config~` as the
   undo; without it the drop-in is a file that looks installed and does nothing.
5. **Talos is out of band**: cluster nodes take the CA through the machine config
   (`ssh: userCAs:`), not this script.

## Rollout (next steps, not done here)

1. Merge the manifests and let ArgoCD create both class engines; confirm both CAs exist and
   record their fingerprints in the docs (`bao read <mount>/config/ca`).
2. `trust` on one low-stakes host per class first — `kubernetes-sandbox` (VM 133) for dev,
   and TrueNAS or the runner for infra — then `issue`, then `verify`.
3. Keep static keys during the break-glass window (the drop-in explicitly leaves
   `authorized_keys` enabled); strip them per host afterwards.
4. Decide the machine-identity binding: today a class policy is granted to a human admin
   token or an out-of-band token. A per-class Keycloak group → OpenBao OIDC role
   (`tokenPolicies: [hnatekmarorg-ssh-class-infra]`) is the declarative version, and the
   `hnatekmarorg-ssh-class-*` policies are already shaped for it.
5. Renewal: certificates are 24h. Renewal is re-`issue` today; an automated path (systemd
   timer with a class-scoped token, or a k8s-auth-backed identity for in-cluster hosts) is
   the next iteration. Nothing to build until a host actually depends on it.
6. Host certificates: the class CAs are CAs, so `allowHostCertificates` + a `host` role per
   class is a one-field change when host-cert trust is wanted — the class then covers both
   directions, and a client trusts the one class CA it needs.

## Open question for the user

The brief said *"all new infra will have one of the two certs"*. This prototype reads that
as **the class CA's trust anchor installed on the host, plus the host's own admin
certificate**, and `enroll.sh` delivers both (`trust` + `issue`). If the intent was only the
inbound half (hosts verify class certs, no machine identity per host), `issue` is simply not
run and nothing else changes — the manifests are the same either way.
