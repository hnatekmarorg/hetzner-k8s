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
| `scripts/ssh-ca/enroll.sh` | runs on a machine: `issue` (default) / `trust` / `verify` / `status` |
| `scripts/ssh-ca/enroll.sh.sha256` | published hash for the `curl | bash` path (regenerate on every change) |
| `scripts/ssh-ca/test-class-separation.sh` | proves the sshd contract without OpenBao (11 cases) |
| `scripts/ssh-ca/test-openbao-contract.sh` | proves the OpenBao contract on a throwaway dev server (18 checks) |
| `scripts/ssh-ca/test-enroll.sh` | proves `enroll.sh` end to end: guards, the CLI-less client path, the hash, dry-run immutability (22 checks) |

Class names are validated, never guessed: an absent, misspelled or mis-cased class is a hard
error, exactly as `clusterClass` refuses to default. Guessing wrong here would mean a machine
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

## Enrollment

`enroll.sh` needs **bash, ssh-keygen and curl** (or wget). No OpenBao CLI, no jq, no python3,
no systemd, and `issue` needs no root: it is built to run as an unprivileged user inside a
container, which is also its default command.

```bash
# host (needs root: writes /etc/ssh and reloads sshd)
enroll.sh --class infra trust                 # trust the infra CA, install the sshd config
enroll.sh --class infra trust --no-reload     # ... without touching sshd
enroll.sh --class dev verify                  # what is installed, and what sshd resolves

# machine identity (works unprivileged, in a container, as CI)
enroll.sh dev                                 # == enroll.sh dev issue
enroll.sh dev --ttl 168h                      # longer-lived, for an image built once
enroll.sh dev --dry-run                       # print every change, write nothing
enroll.sh --check-hash                        # verify this file against its published sha256
```

`issue` writes the key and certificate to `${CLIENT_PREFIX:-$HOME/.ssh/openbao}` and wires
them into `~/.ssh/config.d/openbao-<class>.conf` (adding the `Include` to `~/.ssh/config` if
it is absent, keeping `~/.ssh/config~` as the undo). `verify` fails if both classes' CAs are
trusted by the same host — that state is the silent class merge.

**Container / Dockerfile use.** `$RAW` must be a commit, not `main`, and the token should
come from a BuildKit secret: a token in a `RUN` line or an `ARG` ends up in the image
history.

```Dockerfile
RUN curl -fsSLo /tmp/enroll.sh        "$RAW/scripts/ssh-ca/enroll.sh"        && \
    curl -fsSLo /tmp/enroll.sh.sha256 "$RAW/scripts/ssh-ca/enroll.sh.sha256" && \
    (cd /tmp && sha256sum -c enroll.sh.sha256)                               && \
    bash /tmp/enroll.sh dev --ttl 168h
```

`--check-hash` does the same check from inside the script: it compares this file against
`ENROLL_EXPECT_SHA256` if set, else against the sibling `enroll.sh.sha256`, and refuses to
run on a mismatch. Regenerate the sibling with
`sha256sum enroll.sh > enroll.sh.sha256` — `test-enroll.sh` fails if it has gone stale.

Two operational notes:

- **A certificate baked into an image expires with it.** The 24h role TTL is a poor fit for a
  build-once image, so the example requests `--ttl 168h` (the role's max). The alternative is
  to issue at container start (an entrypoint) and keep the short TTL — pick per use case.
- **ssh reads `~/.ssh/config` from the password database, not `$HOME`.** enroll.sh installs
  into `$HOME` (which is what you want in a container). If you run it with a `HOME` that
  differs from your passwd entry, point ssh at it explicitly: `ssh -F $HOME/.ssh/config …`.
  `verify` says so when it cannot resolve the certificate.

Credentials: `BAO_TOKEN` / `VAULT_TOKEN`, `--token`, or `~/.vault-token` (what login writes).
A machine should carry a class-scoped token (policy `hnatekmarorg-ssh-class-<class>`), never
the human admin token; the token is never printed. `trust` additionally needs `read` on
`<mount>/config/ca`, which returns the **public** key only.

## Verification

Three hermetic harnesses, run by hand — `bash scripts/ssh-ca/test-*.sh`, about a minute
together. They need `curl`, `ssh-keygen` and (for the two that start a server) a `bao` or
`vault` binary; nothing else, and no live infrastructure.

**`test-class-separation.sh`** — two local CAs, five throwaway sshds on 127.0.0.1, nothing
under `/etc/ssh` touched. Probes authentication only (`ssh -N` + timeout; 124 = accepted,
255 = refused), so the result cannot be confounded by hosts whose SELinux policy prevents a
test sshd from exec'ing a shell:

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

**`test-openbao-contract.sh`** — a `bao server -dev` (in-memory): two independent class CAs,
the role fields round-trip, the issued certificate carries `principals = admin`, the key id,
a 24h window and the `source-address` pin, a request for `valid_principals = root` is
refused, `default_user` outside `allowed_users` is refused, and a token holding one class's
policy can sign its own class, read its own trust anchor, and is refused on the other class.

**`test-enroll.sh`** — a real run of the container/CI path: a throwaway OpenBao, a fake
`HOME`, and `bao`/`vault` replaced by stubs that fail if called, so "no OpenBao CLI needed"
is enforced rather than assumed. It checks the class guard (absent, misspelled, mis-cased),
that `enroll.sh dev --ttl 168h` installs a certificate with the right principal, key id, TTL
and CA, that **ssh really resolves the identity** through the `~/.ssh/config` include, that a
dev token is refused on the infra signing path, that the published sha256 matches, and that
`--dry-run` leaves `/etc/ssh` and `$HOME/.ssh` byte-identical. It also checks its own fixture
(policy created, token can sign) before blaming `enroll.sh` for anything.

## Findings from building it

1. **`cidrList` does nothing on CA-type roles — including the ones already in this repo.**
   The OpenBao API documents `cidr_list` as *"Not applicable for CA type"* (it belongs to
   OTP-type roles), and a dev-server test confirms it: a CA role with `cidr_list` set issues a
   certificate with `Critical Options: (none)`. So `ssh/role.yaml`, `ssh/infra-role.yaml` and
   `algovectra/ssh/role.yaml` carry dead config, and the overhaul plan's Phase 2 step 1
   (*"tighten cidrList 0.0.0.0/0 → …"*) would not have changed behaviour. The class roles use
   `defaultCriticalOptions.source-address` instead — verified to land on the certificate and
   enforced by sshd (case 9).
   Residual: a caller holding *sign* rights can override `critical_options`, so this bounds a
   leaked certificate, not a leaked signing token. The class gate cannot be overridden this way.
2. **`key_id` is refused unless the role sets `allow_user_key_ids: true`** — the engine
   answers `setting key_id is not allowed by role` otherwise. Hence the field on both roles:
   it is what makes `ssh-keygen -L` and the sshd log say *which machine, which class*.
3. **`default_user` is the principal — and it must be a member of `allowed_users`.**
   OpenBao validates it: with `allowed_users: admin`, a role whose `default_user` is `root`
   refuses even a principal-less sign (`root is not a valid value for valid_principals`), so
   `default_user: root` here is a *broken* default, not a looser one. The class roles set both
   fields to `admin`, and `ssh root@host` is unaffected — the login user comes from the client.
   **The tier deliberately is not a login name.** sshd matches a certificate principal against
   the target login *directly*, with no `AuthorizedPrincipalsFile` involved. Measured
   (cases 10/11): on a host with `TrustedUserCAKeys` and no principals file, a
   `principals=[root]` certificate is accepted for `root` while the tier-gated `admin` one is
   refused. A tier named `root` would therefore work by default on any unconfigured host —
   silently skipping the gate — whereas `admin` makes such a host refuse everything until the
   principals file is in place. Fails closed, by naming.
4. **Key material needs JSON unescaping.** OpenBao returns `signed_key` with a trailing
   newline, JSON-escaped as `\n`. A naive `sed` extraction keeps the two characters and
   ssh-keygen rejects the certificate (`invalid format`) — which cost a debugging round, and
   is why `enroll.sh` now decodes the escapes *and* parses every key it installs before
   installing it.
5. **Debian's `sshd_config` has no `sshd_config.d` include by default** (Proxmox hosts are
   Debian). `enroll.sh` detects this, inserts the include, and keeps `sshd_config~` as the
   undo; without it the drop-in is a file that looks installed and does nothing.
6. **Talos is out of band**: cluster nodes take the CA through the machine config
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
5. Renewal: certificates are 24h (168h max). Renewal is re-`issue` today; an automated path
   (systemd timer, container entrypoint, or a k8s-auth-backed identity for in-cluster hosts)
   is the next iteration. Nothing to build until a machine actually depends on it.
6. Host certificates: the class CAs are CAs, so `allowHostCertificates` + a `host` role per
   class is a one-field change when host-cert trust is wanted — the class then covers both
   directions, and a client trusts the one class CA it needs.

## Open question for the user

The brief said *"all new infra will have one of the two certs"*. This prototype reads that
as **the class CA's trust anchor installed on the host, plus the host's own admin
certificate**, and `enroll.sh` delivers both (`trust` + `issue`). If the intent was only the
inbound half (hosts verify class certs, no machine identity per host), `issue` is simply not
run and nothing else changes — the manifests are the same either way.
