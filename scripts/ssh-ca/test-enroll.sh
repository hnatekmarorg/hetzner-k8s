#!/usr/bin/env bash
#
# test-enroll.sh — verify enroll.sh end to end, with only curl + openssh available.
#
# What it proves, and why each one matters:
#   * the class guard refuses an absent/misspelled/mis-cased class (never guesses)
#   * `enroll.sh dev` works with NO OpenBao CLI on PATH and a token read from
#     ~/.vault-token — the container/CI path, run against a throwaway dev server
#   * the certificate it installs is the right one: principal `admin`, key id
#     `<class>:<host>`, the requested TTL, signed by that class's CA
#   * ssh actually resolves the identity (CertificateFile via the ~/.ssh/config Include)
#     — i.e. the wiring is real, not just files on disk
#   * a token scoped to the other class is refused, with the policy named in the error
#   * the published sha256 matches this file (so the Dockerfile hash check cannot go stale)
#   * --dry-run changes nothing under /etc/ssh or $HOME (hash-for-hash)
#
# The fixture is provisioned over the HTTP API with curl, so the whole file needs only
# curl, ssh-keygen and ssh — the same dependencies enroll.sh has.
#
# Usage: test-enroll.sh [--port 8250]
#
set -euo pipefail

PORT=8250
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENROLL="$HERE/enroll.sh"
[[ -f "$ENROLL" ]] || { echo "enroll.sh not found next to this script" >&2; exit 2; }

if command -v bao >/dev/null 2>&1; then SRV_CLI=bao
elif command -v vault >/dev/null 2>&1; then SRV_CLI=vault
else echo "the test needs a bao/vault binary to start a throwaway server" >&2; exit 2; fi

ADDR="http://127.0.0.1:${PORT}"
W="$(mktemp -d /tmp/ssh-ca-enroll.XXXXXX)"
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true; rm -rf "$W"; }
trap cleanup EXIT

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

# ------------------------------------------------------------------ throwaway OpenBao

"$SRV_CLI" server -dev -dev-root-token-id=root -dev-no-store-token \
  -dev-listen-address="127.0.0.1:${PORT}" >"$W/server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do curl -sS -o /dev/null "$ADDR/v1/sys/health" 2>/dev/null && break; sleep 0.5; done

api() {  # <METHOD-ish: post|get> <path> [json]
  local verb="$1" path="$2" body="${3:-}"
  if [[ "$verb" == post ]]; then
    printf '%s' "$body" | curl -sS -X POST -H 'X-Vault-Token: root' \
      -H 'Content-Type: application/json' --data-binary @- "$ADDR/v1/$path"
  else
    curl -sS -H 'X-Vault-Token: root' "$ADDR/v1/$path"
  fi
}

json_str() {  # <field> ; JSON on stdin — key material is single-line, and OpenBao escapes
              # the newline it appends as \n, which must not survive into the file
  sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1 \
    | sed -e 's/\\n/\n/g' -e 's/\\r//g' -e 's|\\/|/|g' -e 's/\\"/"/g' | tr -d '\n' | sed 's/[[:space:]]*$//'
}

provision_class() {  # <class>  (mirrors the Crossplane manifests)
  local c="$1" m="hnatekmarorg-ssh-$1"
  api post "sys/mounts/$m" '{"type":"ssh"}' >/dev/null
  api post "$m/config/ca" '{"generate_signing_key":true}' >"$W/ca_$c.json"
  json_str public_key <"$W/ca_$c.json" >"$W/ca_$c.pub"
  cat >"$W/role_$c.json" <<EOF
{"key_type":"ca","default_user":"admin","allowed_users":"admin","ttl":"24h","max_ttl":"168h",
 "allow_host_certificates":false,"allow_user_certificates":true,"allow_user_key_ids":true,
 "default_critical_options":{"source-address":"172.16.0.0/20,192.168.88.0/24"},
 "allowed_extensions":"permit-pty,permit-port-forwarding",
 "default_extensions":{"permit-pty":""},"not_before_duration":"30s"}
EOF
  api post "$m/roles/admin" "$(cat "$W/role_$c.json")" >/dev/null
  api post "sys/policies/acl/hnatekmarorg-ssh-class-$c" \
    "{\"policy\":\"path \\\"$m/sign/admin\\\" { capabilities = [\\\"create\\\",\\\"update\\\"] }\\npath \\\"$m/config/ca\\\" { capabilities = [\\\"read\\\"] }\"}" >/dev/null
}

provision_class dev

# Class-scoped tokens: `dev` may sign dev only.
token_for() {  # <class>
  api post "auth/token/create" "{\"policies\":[\"hnatekmarorg-ssh-class-$1\"],\"ttl\":\"5m\"}" | json_str client_token
}
DEV_TOKEN="$(token_for dev)"
[[ -n "$DEV_TOKEN" ]] || { echo "could not mint a test token" >&2; exit 3; }

# Fixture self-check. A policy that silently failed to create, or a token that silently
# lacks it, would otherwise show up as an enroll.sh failure — blame the right component.
FIXTURE_OK=1
api get "sys/policies/acl/hnatekmarorg-ssh-class-dev" | grep -q hnatekmarorg-ssh-dev || FIXTURE_OK=0
rm -f "$W/preflight" "$W/preflight.pub"
ssh-keygen -q -t ed25519 -N '' -f "$W/preflight"
PREFLIGHT_CODE="$(printf '{"public_key":"%s","valid_principals":"admin","cert_type":"user","ttl":"5m"}' "$(cat "$W/preflight.pub")" \
  | curl -sS -o "$W/preflight.out" -w '%{http_code}' -X POST -H "X-Vault-Token: $DEV_TOKEN" \
    -H 'Content-Type: application/json' --data-binary @- "$ADDR/v1/hnatekmarorg-ssh-dev/sign/admin")"
[[ "$PREFLIGHT_CODE" == 200 ]] || FIXTURE_OK=0
if [[ "$FIXTURE_OK" == 1 ]]; then
  ok "fixture sound: dev policy exists and its token can sign (HTTP $PREFLIGHT_CODE)"
else
  bad "fixture broken (policy read / preflight sign HTTP $PREFLIGHT_CODE) — test setup, not enroll.sh: $(head -c 200 "$W/preflight.out")"
fi

# Fake HOME: the client identity must land there, not in the real /root.
export HOME="$W/home"
mkdir -p "$HOME"
printf '%s' "$DEV_TOKEN" >"$HOME/.vault-token"      # what `bao login` writes

# A PATH with curl/ssh-keygen but deliberately NO bao/vault: proves the CLI is not needed.
mkdir -p "$W/bin"
for t in bao vault; do printf '#!/bin/sh\necho "the %s CLI must not be needed by enroll.sh" >&2\nexit 127\n' "$t" >"$W/bin/$t"; chmod +x "$W/bin/$t"; done
export PATH="$W/bin:$PATH"

echo "enroll.sh end to end (throwaway OpenBao on $ADDR, HOME=$HOME)"

# ---------------------------------------------------------------------------- guards

# Every enroll.sh call goes through this: the address must be the throwaway server (not the
# default live endpoint, which would 403 correctly and look like a script bug), and the
# token must come from the file rather than the ambient environment.
enroll() { env -u BAO_TOKEN -u VAULT_TOKEN BAO_ADDR="$ADDR" bash "$ENROLL" "$@"; }

guard() {  # <description> <pattern> <args...>
  local desc="$1" pattern="$2"; shift 2
  local out rc
  set +e; out="$(enroll "$@" 2>&1)"; rc=$?; set -e
  if [[ "$rc" != 0 ]] && grep -qiE "$pattern" <<<"$out"; then
    ok "$desc — refused (rc=$rc)"
  else
    bad "$desc — expected refusal matching /$pattern/, got rc=$rc"
    sed 's/^/          /' <<<"$out" | tail -3
  fi
}

guard "no class at all"            "class is required"        issue
guard "typo class (devl)"          "must be 'infra' or 'dev'" devl
guard "wrong case (Infra)"         "must be 'infra' or 'dev'" Infra
guard "unknown option"             "unknown option"           dev --frobnicate
guard "unknown argument"           "unrecognised argument"    dev sideways

# ------------------------------------------------------- the container/CI path, for real

echo "  --- bash enroll.sh dev --ttl 168h"
set +e
OUT="$(enroll dev --ttl 168h 2>&1)"; RC=$?
set -e
if [[ "$RC" == 0 ]]; then ok "enroll.sh dev exits 0 (no Bao CLI on PATH)"; else bad "enroll.sh dev exited $RC"; sed 's/^/          /' <<<"$OUT" | tail -5; fi

KEY="$HOME/.ssh/openbao/id_ed25519"
CERT="$KEY-cert.pub"
[[ -f "$KEY" && -f "$CERT" ]] && ok "key and certificate installed under \$HOME/.ssh/openbao" \
  || bad "key/certificate missing ($KEY, $CERT)"
[[ -n "$DEV_TOKEN" ]] && ! grep -q "$DEV_TOKEN" <<<"$OUT" \
  && ok "the token never appears in the output" || bad "the token leaked into the output"

if [[ -f "$CERT" ]]; then
  ssh-keygen -L -f "$CERT" >"$W/cert.txt"
  grep -q '^ *admin$' "$W/cert.txt" && ok "certificate principal is admin" || bad "principal is not admin"
  grep -q "Key ID: \"dev:" "$W/cert.txt" && ok "key id carries class:host" || bad "key id missing class:host"
  # TTL: the image/CI case needs more than the 24h default.
  end="$(sed -n 's/^ *Valid: from .* to \(.*\)$/\1/p' "$W/cert.txt")"
  if [[ -n "$end" ]]; then
    secs=$(( $(date -d "$end" +%s) - $(date +%s) ))
    if (( secs > 150000 && secs <= 168*3600 )); then
      ok "requested TTL honoured (~$(( secs / 3600 ))h of the 168h max)"
    else
      bad "TTL looks wrong: $(( secs / 3600 ))h (expected ~168h)"
    fi
  fi
  # Signed by the class CA, not merely by some CA.
  want_ca="$(ssh-keygen -lf "$W/ca_dev.pub" | awk '{print $2}')"
  grep -q "$want_ca" "$W/cert.txt" && ok "certificate is signed by the dev class CA" \
    || bad "certificate is not signed by the dev CA ($want_ca)"
fi

# Does ssh actually use it? (the ~/.ssh/config Include + drop-in wiring)
# `-F` points ssh at the generated config explicitly: ssh resolves ~ from the password
# database rather than $HOME, and the test deliberately runs with a throwaway HOME.
if grep -q "^Include .*/\.ssh/config\.d/\*\.conf$" "$HOME/.ssh/config" 2>/dev/null; then
  ok "~/.ssh/config carries the Include for config.d/"
else
  bad "no Include for ~/.ssh/config.d/ in ~/.ssh/config"
fi
if command -v ssh >/dev/null 2>&1; then
  if ssh -F "$HOME/.ssh/config" -G example.invalid 2>/dev/null | grep -qi "^certificatefile ${CERT}$"; then
    ok "ssh resolves CertificateFile=$CERT from the config.d drop-in"
  else
    bad "ssh does not resolve the certificate from the drop-in"
    ssh -F "$HOME/.ssh/config" -G example.invalid 2>/dev/null | grep -i certificatefile | sed 's/^/          /' || true
  fi
fi

enroll dev verify >"$W/verify.out" 2>&1 \
  && ok "enroll.sh dev verify reports PASS" || { bad "verify did not pass"; sed 's/^/          /' "$W/verify.out" | tail -5; }

# A token for one class must not be able to sign the other.
api post "sys/mounts/hnatekmarorg-ssh-infra" '{"type":"ssh"}' >/dev/null
api post "hnatekmarorg-ssh-infra/config/ca" '{"generate_signing_key":true}' >/dev/null
printf '{"key_type":"ca","default_user":"admin","allowed_users":"admin","allow_user_certificates":true,"ttl":"24h"}' \
  | curl -sS -X POST -H 'X-Vault-Token: root' -H 'Content-Type: application/json' --data-binary @- \
    "$ADDR/v1/hnatekmarorg-ssh-infra/roles/admin" >/dev/null
set +e
OUT2="$(enroll infra 2>&1)"; RC2=$?
set -e
if [[ "$RC2" != 0 ]] && grep -qi "hnatekmarorg-ssh-class-infra" <<<"$OUT2"; then
  ok "a dev-class token is refused on the infra signing path (and the policy is named)"
else
  bad "expected a refusal naming hnatekmarorg-ssh-class-infra, got rc=$RC2"
  sed 's/^/          /' <<<"$OUT2" | tail -3
fi

# ------------------------------------------------------------------- hash + dry-run

if enroll --check-hash >"$W/hash.out" 2>&1; then
  ok "the published sha256 matches enroll.sh ($(awk '{print $1}' "$ENROLL.sha256" | cut -c1-12)…)"
else
  bad "sha256 mismatch — regenerate with: sha256sum enroll.sh > enroll.sh.sha256"
  sed 's/^/          /' "$W/hash.out" | tail -3
fi
if ENROLL_EXPECT_SHA256="$(printf '0%.0s' {1..64})" enroll dev --check-hash >/dev/null 2>&1; then
  bad "a wrong ENROLL_EXPECT_SHA256 was accepted"
else
  ok "a wrong ENROLL_EXPECT_SHA256 is rejected"
fi

snapshot() { find /etc/ssh "$HOME/.ssh" -type f -exec sha256sum {} \; 2>/dev/null | sort; }
BEFORE="$(snapshot)"
enroll --class infra trust --dry-run >"$W/dry_trust.out" 2>&1 || bad "--class infra trust --dry-run failed"
enroll dev --dry-run             >"$W/dry_issue.out" 2>&1 || bad "dev --dry-run failed"
# The dry-run output is also the only place the *content* of the host drop-in is visible
# without writing it: check the class key and the tier gate are what they must be.
if grep -q "TrustedUserCAKeys /etc/ssh/ssh_ca_infra.pub" "$W/dry_trust.out" \
   && grep -q "AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u" "$W/dry_trust.out"; then
  ok "the infra drop-in carries the infra CA and the principals gate"
else
  bad "the infra drop-in content is wrong"
  sed 's/^/          /' "$W/dry_trust.out" | tail -8
fi
if grep -q "ssh_ca_dev.pub" "$W/dry_trust.out"; then
  bad "the infra drop-in mentions the dev CA — the classes would be mixed"
else
  ok "the infra drop-in does not mention the dev class"
fi
AFTER="$(snapshot)"
if [[ "$BEFORE" == "$AFTER" ]]; then
  ok "dry-run changed nothing under /etc/ssh or \$HOME/.ssh (hash-for-hash)"
else
  bad "dry-run modified files:"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/          /' | head -8
fi

echo
if [[ "$fail" == 0 ]]; then
  echo "enroll.sh refuses an unstated class, needs no Bao CLI, and its identity is really used by ssh."
else
  echo "problems found — see the FAIL lines above."
fi
exit "$fail"
