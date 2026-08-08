# hnatekmarorg — secret registry

No KV mount — this tenant holds SSH signing (CA, mount, roles) and its own policies.

| Resource | Purpose |
|---|---|
| `hnatekmarorg-ssh` | SSH CA + roles (user, infra) |
| `hnatekmarorg`, `hnatekmarorg-admin` | SSO policies for the hnatekmarorg group |

SSH engine files: `ssh/ca.yaml`, `ssh/mount.yaml`, `ssh/role.yaml`, `ssh/infra-role.yaml`.
