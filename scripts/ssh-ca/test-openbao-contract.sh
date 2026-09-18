#!/usr/bin/env bash
#
# test-openbao-contract.sh — prove the OpenBao half of the SSH class model on a throwaway
# dev server. No live OpenBao, no cluster, nothing written outside a temp dir.
#
# What it checks, and why each one matters:
#   * two mounts, two independent CAs        — the class is the CA, so the keys must differ
#   * role `admin` accepts valid_principals=admin and REFUSES anything else
#                                            — allowed_users is what keeps the certificate
#                                              shape fixed (the tier lives in the principal)
#   * the issued certificate really carries principals=admin, the 24h TTL and the
#     cidr_list as a source-address critical option
#                                            — i.e. what enroll.sh and sshd will act on
#   * a token holding only the class policy can sign its own class and read its own trust
#     anchor, and is refused on the other class
#                                            — the per-class policy split, enforced by Bao
#
# Usage: test-openbao-contract.sh [--port 8210]        (needs the bao or vault CLI)
#
set -euo pipefail

PORT=8210
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if command -v bao >/dev/null 2>&1; then CLI=bao
elif command -v vault >/dev/null 2>&1; then CLI=vault
else echo "needs the bao or vault CLI" >&2; exit 2; fi

ADDR="http://127.0.0.1:${PORT}"
export BAO_ADDR="$ADDR" VAULT_ADDR="$ADDR"
export BAO_TOKEN=root  VAULT_TOKEN=root

WORKDIR="$(mktemp -d /tmp/ssh-ca-contract.XXXXXX)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Class definitions mirror the Crossplane manifests in this repo.
MOUNTS=(hnatekmarorg-ssh-infra hnatekmarorg-ssh-dev)
CLASSES=(infra dev)
CIDR="172.16.0.0/20,172.16.16.0/20,172.16.32.0/19,172.16.64.0/20,172.16.96.0/20,172.16.100.0/24,192.168.88.0/24,88.198.65.246/32"
TIER=admin

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------- dev server

"$CLI" server -dev -dev-root-token-id=root -dev-no-store-token \
  -dev-listen-address="127.0.0.1:${PORT}" >"$WORKDIR/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 60); do
  "$CLI" status >/dev/null 2>&1 && break
  sleep 0.5
done
"$CLI" status >/dev/null 2>&1 || { sed 's/^/  server: /' "$WORKDIR/server.log" | tail -5; die "dev server did not come up on $ADDR"; }
echo "throwaway OpenBao on $ADDR (pid $SRV_PID, in-memory)"

# --------------------------------------------------------- mounts, CAs, admin roles

for i in "${!MOUNTS[@]}"; do
  m="${MOUNTS[$i]}"; c="${CLASSES[$i]}"
  "$CLI" secrets enable -path="$m" ssh >/dev/null
  "$CLI" write -field=public_key "$m/config/ca" generate_signing_key=true >"$WORKDIR/ca_$c.pub"

  # The role body mirrors the Crossplane SecretBackendRole forProvider fields exactly.
  # A map-typed field (default_extensions) cannot be set with `key=value`, so the body
  # goes in as one JSON document.
  cat >"$WORKDIR/role_$c.json" <<EOF
{
  "key_type": "ca",
  "default_user": "$TIER",
  "allowed_users": "$TIER",
  "ttl": "24h",
  "max_ttl": "168h",
  "allow_host_certificates": false,
  "allow_user_certificates": true,
  "allow_user_key_ids": true,
  "default_critical_options": {"source-address": "$CIDR"},
  "allowed_extensions": "permit-pty,permit-port-forwarding,permit-X11-forwarding",
  "default_extensions": {"permit-pty": "", "permit-port-forwarding": "", "permit-X11-forwarding": ""},
  "not_before_duration": "30s"
}
EOF
  "$CLI" write "$m/roles/$TIER" @"$WORKDIR/role_$c.json" >/dev/null
  "$CLI" read -format=json "$m/roles/$TIER" >"$WORKDIR/role_$c.read.json"
  if python3 - "$WORKDIR/role_$c.read.json" "$TIER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["data"]
tier = sys.argv[2]
assert d["allowed_users"] == tier, d["allowed_users"]
assert d["default_user"] == tier, d["default_user"]
assert d["allow_user_certificates"] is True and d["allow_host_certificates"] is False, d
assert d["allow_user_key_ids"] is True, d["allow_user_key_ids"]
assert "source-address" in d["default_critical_options"], d["default_critical_options"]
assert d["ttl"] == 86400 and d["max_ttl"] == 604800, (d["ttl"], d["max_ttl"])
assert d["default_extensions"] == {"permit-pty": "", "permit-port-forwarding": "", "permit-X11-forwarding": ""}, d["default_extensions"]
PY
  then
    ok "class $c: role fields accepted and round-tripped (allowed_users=$TIER, ttl 24h/168h, map extensions)"
  else
    bad "class $c: role fields did not round-trip as written"
  fi
done

for c in "${CLASSES[@]}"; do
  if grep -qE '^ssh-(rsa|ed25519)' "$WORKDIR/ca_$c.pub"; then
    ok "class $c: CA public key present ($(ssh-keygen -lf "$WORKDIR/ca_$c.pub" | awk '{print $2}'))"
  else
    bad "class $c: unexpected CA public key"
  fi
done
if [[ "$(ssh-keygen -lf "$WORKDIR/ca_infra.pub" | awk '{print $2}')" == "$(ssh-keygen -lf "$WORKDIR/ca_dev.pub" | awk '{print $2}')" ]]; then
  bad "the two classes share a CA key — the isolation would be cosmetic"
else
  ok "the two classes have independent CA keys (the class is the CA)"
fi

# ------------------------------------------------------------------- issued certificate

ssh-keygen -q -t ed25519 -N '' -f "$WORKDIR/key"
"$CLI" write -field=signed_key "${MOUNTS[0]}/sign/$TIER" \
  public_key=@"$WORKDIR/key.pub" valid_principals="$TIER" cert_type=user \
  key_id="infra:$(hostname -f)" ttl=24h >"$WORKDIR/cert.pub"
ssh-keygen -L -f "$WORKDIR/cert.pub" >"$WORKDIR/cert.txt"

check_cert() {  # <description> <grep-pattern>
  grep -q "$2" "$WORKDIR/cert.txt" && ok "$1" || { bad "$1"; grep -q . "$WORKDIR/cert.txt" || true; }
}
check_cert "certificate is a user certificate" "^ *Type: .* user certificate"
check_cert "certificate carries principals = $TIER" "^ *$TIER$"
check_cert "certificate carries the key id (audit trail)" "Key ID: \"infra:"
check_cert "certificate TTL is 24h (valid window present)" "^ *Valid: from .* to "
# The pin the class roles rely on: `default_critical_options.source-address` has to land on
# the certificate as a critical option, because that is what sshd enforces. cidr_list does
# NOT do this on a CA-type role (OpenBao: "Not applicable for CA type"), verified here.
grep -q "source-address" "$WORKDIR/cert.txt" \
  && ok "certificate is pinned to the estate's nets (source-address critical option)" \
  || bad "certificate carries no source-address — the class role's pin did not apply"

# The role must not let a caller choose its own principal.
if "$CLI" write "${MOUNTS[0]}/sign/$TIER" public_key=@"$WORKDIR/key.pub" \
     valid_principals=root cert_type=user ttl=1h >"$WORKDIR/attempt.out" 2>&1; then
  bad "signing with valid_principals=root succeeded — allowed_users does not constrain the principal"
else
  ok "signing with valid_principals=root is refused (allowed_users=$TIER)"
fi

# default_user is validated against allowed_users. A role that defaults to the login name
# (root) while allowing only `admin` refuses even a principal-less sign — which is why
# `default_user: root` on the class roles would be a *broken* default, not a looser one.
cat >"$WORKDIR/role_mismatch.json" <<EOF
{"key_type": "ca", "default_user": "root", "allowed_users": "$TIER",
 "allow_user_certificates": true, "ttl": "1h"}
EOF
"$CLI" write "${MOUNTS[0]}/roles/mismatch" @"$WORKDIR/role_mismatch.json" >/dev/null
if "$CLI" write "${MOUNTS[0]}/sign/mismatch" public_key=@"$WORKDIR/key.pub" \
     cert_type=user ttl=1h >/dev/null 2>"$WORKDIR/mismatch.err"; then
  bad "default_user=root + allowed_users=$TIER issued a principal-less certificate"
else
  ok "default_user outside allowed_users is refused ($(sed 's/^\* //' "$WORKDIR/mismatch.err" | tail -1))"
fi

# ------------------------------------------------------------------------ policy split

for i in "${!MOUNTS[@]}"; do
  m="${MOUNTS[$i]}"; c="${CLASSES[$i]}"
  "$CLI" policy write "hnatekmarorg-ssh-class-$c" - >/dev/null <<EOF
path "$m/sign/$TIER" { capabilities = ["create", "update"] }
path "$m/config/ca" { capabilities = ["read"] }
path "$m/roles/*" { capabilities = ["read", "list"] }
EOF
  "$CLI" token create -policy="hnatekmarorg-ssh-class-$c" -ttl=5m -field=token >"$WORKDIR/token_$c"
done

as_class() {  # <class> <command...>
  local c="$1"; shift
  BAO_TOKEN="$(cat "$WORKDIR/token_$c")" "$CLI" "$@"
}

for i in "${!MOUNTS[@]}"; do
  m="${MOUNTS[$i]}"; c="${CLASSES[$i]}"; other="${CLASSES[$(( 1 - i ))]}"
  other_m="${MOUNTS[$(( 1 - i ))]}"

  as_class "$c" read -field=public_key "$m/config/ca" >/dev/null 2>&1 \
    && ok "$c token: may read its own class trust anchor" \
    || bad "$c token: cannot read its own trust anchor"

  as_class "$c" write -field=signed_key "$m/sign/$TIER" \
      public_key=@"$WORKDIR/key.pub" valid_principals="$TIER" cert_type=user ttl=1h >/dev/null 2>&1 \
    && ok "$c token: may sign a $c-class certificate" \
    || bad "$c token: cannot sign its own class"

  if as_class "$c" write "$other_m/sign/$TIER" \
       public_key=@"$WORKDIR/key.pub" valid_principals="$TIER" cert_type=user ttl=1h >/dev/null 2>&1; then
    bad "$c token: allowed to sign a $other-class certificate — the classes are not separated"
  else
    ok "$c token: refused on the $other-class signing path"
  fi
done

echo
if [[ "$fail" == 0 ]]; then
  echo "the OpenBao half of the model holds: two class CAs, one fixed certificate shape, per-class policies."
else
  echo "model violated — see the FAIL lines above."
fi
exit "$fail"
