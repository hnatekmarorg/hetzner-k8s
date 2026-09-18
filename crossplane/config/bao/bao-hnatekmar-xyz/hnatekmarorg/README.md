# hnatekmarorg — secret registry

No KV mount — this tenant holds SSH signing (CA, mounts, roles) and its own policies.

| Resource | Purpose |
|---|---|
| `hnatekmarorg-ssh` | SSH CA + roles (user, infra/host) for people and host certificates |
| `hnatekmarorg-ssh-infra` | **infra-class** SSH CA + `admin` role — hosts that must keep working (balteus, TrueNAS, GitHub runner) |
| `hnatekmarorg-ssh-dev` | **dev-class** SSH CA + `admin` role — sandboxes, free to break (kubernetes-sandbox / VM 133) |
| `hnatekmarorg`, `hnatekmarorg-admin` | SSO policies for the hnatekmarorg group |
| `hnatekmarorg-ssh-class-infra`, `hnatekmarorg-ssh-class-dev` | per-class signing policies (shaped for a group → OIDC role binding) |

The classes are two CAs on purpose: a host trusts one class CA, so the other class's
certificate does not verify there. Design, contract and rollout: `docs/crossplane/ssh-ca-classes.md`.

SSH engine files: `ssh/ca.yaml`, `ssh/mount.yaml`, `ssh/role.yaml`, `ssh/infra-role.yaml`
and `ssh/classes/{infra,dev}/{mount,ca,role-admin}.yaml` for the class engines.

Note: `cidrList` on a `key_type: ca` role does nothing — the OpenBao API documents
`cidr_list` as *"Not applicable for CA type"*. The class roles pin the estate's nets through
`defaultCriticalOptions.source-address` instead; the older `ssh/*-role.yaml` files still
carry the inert field.
