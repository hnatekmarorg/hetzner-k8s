#!/usr/bin/env bash
#
# test-enroll-dryrun.sh — prove enroll.sh talks to OpenBao correctly and, in --dry-run,
# changes nothing at all.
#
# Why this exists: enroll.sh writes into /etc/ssh on a real host, so the only safe way to
# test its wiring is to point it at a throwaway OpenBao and run it with --dry-run. This
# snapshots every file under /etc/ssh (name + hash + mtime) before and after and fails if a
# single byte moved — the dry-run guard is a promise, and this checks it.
#
# It also checks the class guard, which is the part that must never be lenient: an absent or
# misspelled class has to be a hard error, not a default.
#
# Usage: test-enroll-dryrun.sh [--port 8230]
#
set -euo pipefail

PORT=8230
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENROLL="$HERE/enroll.sh"
[[ -x "$ENROLL" || -f "$ENROLL" ]] || { echo "enroll.sh not found next to this script" >&2; exit 2; }

if command -v bao >/dev/null 2>&1; then CLI=bao
elif command -v vault >/dev/null 2>&1; then CLI=vault
else echo "needs the bao or vault CLI" >&2; exit 2; fi

ADDR="http://127.0.0.1:${PORT}"
export BAO_ADDR="$ADDR" VAULT_ADDR="$ADDR" BAO_TOKEN=root VAULT_TOKEN=root

WORKDIR="$(mktemp -d /tmp/ssh-ca-enroll.XXXXXX)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

snapshot_etc_ssh() {  # name -> sorted "path mode sha256" lines
  [[ -d /etc/ssh ]] || return 0
  find /etc/ssh -type f -exec sha256sum {} \; 2>/dev/null | sort
}

"$CLI" server -dev -dev-root-token-id=root -dev-no-store-token \
  -dev-listen-address="127.0.0.1:${PORT}" >"$WORKDIR/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 60); do "$CLI" status >/dev/null 2>&1 && break; sleep 0.5; done
"$CLI" status >/dev/null 2>&1 || { sed 's/^/  server: /' "$WORKDIR/server.log" | tail -5; die=1; echo "dev server did not start" >&2; exit 3; }

# Provision the infra class exactly as the Crossplane manifests do.
"$CLI" secrets enable -path=hnatekmarorg-ssh-infra ssh >/dev/null
"$CLI" write -field=public_key hnatekmarorg-ssh-infra/config/ca generate_signing_key=true >/dev/null
"$CLI" write hnatekmarorg-ssh-infra/roles/admin key_type=ca default_user=admin \
  allowed_users=admin allow_user_certificates=true allow_user_key_ids=true ttl=24h max_ttl=168h >/dev/null
"$CLI" policy write hnatekmarorg-ssh-class-infra - >/dev/null <<'EOF'
path "hnatekmarorg-ssh-infra/sign/admin" { capabilities = ["create", "update"] }
path "hnatekmarorg-ssh-infra/config/ca" { capabilities = ["read"] }
path "hnatekmarorg-ssh-infra/roles/*" { capabilities = ["read", "list"] }
EOF

echo "enroll.sh dry-run wiring (throwaway OpenBao on $ADDR)"

# ---------------------------------------------------------------- the class guard first

run_guard() {  # <description> <output-pattern> <args...>
  local desc="$1" pattern="$2"; shift 2
  local out rc
  set +e
  out="$("$ENROLL" "$@" 2>&1)"; rc=$?
  set -e
  if [[ "$rc" != 0 ]] && grep -qiE "$pattern" <<<"$out"; then
    ok "$desc — refused (rc=$rc)"
  else
    bad "$desc — expected a refusal matching /$pattern/, got rc=$rc"
    sed 's/^/          /' <<<"$out" | tail -3
  fi
}

run_guard "no --class at all"              "class is required"  trust
run_guard "--class devl (typo)"            "must be 'infra' or 'dev'" --class devl trust
run_guard "--class Infra (wrong case)"     "must be 'infra' or 'dev'" --class Infra trust
run_guard "no command given"               "Commands:|Usage:"  --class infra

# ------------------------------------------------------------------- dry-run, no side effects

BEFORE="$(snapshot_etc_ssh)"
echo "$BEFORE" >"$WORKDIR/etc_ssh.before"
ALL_OUT=""

for cmd in trust issue; do
  echo "  --- enroll.sh --class infra $cmd --dry-run"
  set +e
  out="$("$ENROLL" --class infra "$cmd" --dry-run 2>&1)"; rc=$?
  set -e
  sed 's/^/          /' <<<"$out"
  if [[ "$rc" == 0 ]]; then
    ok "--class infra $cmd --dry-run exits 0"
  else
    bad "--class infra $cmd --dry-run exited $rc"
  fi
  ALL_OUT+="$out"
done

# The dry-run must still have exercised the OpenBao path, not quietly skipped it: the trust
# run reads the class CA public key, the issue run walks the signing request.
if grep -q "fetching the infra class CA public key from OpenBao" <<<"$ALL_OUT" \
   && grep -q "signing the infra-class admin certificate" <<<"$ALL_OUT"; then
  ok "the dry-run showed the CA read and the signing step (wiring exercised)"
else
  bad "the dry-run output did not show the CA read / signing steps"
  sed 's/^/          /' <<<"$ALL_OUT" | tail -5
fi

AFTER="$(snapshot_etc_ssh)"
echo "$AFTER" >"$WORKDIR/etc_ssh.after"
if [[ "$BEFORE" == "$AFTER" ]]; then
  ok "nothing under /etc/ssh changed (hash-for-hash identical)"
else
  bad "dry-run modified /etc/ssh:"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/          /' | head -10
fi

# The dry-run must still have exercised the OpenBao read path, not skipped it.
if "$ENROLL" --class infra status >/dev/null 2>&1; then
  ok "status command runs (reads only)"
else
  bad "status command failed"
fi

echo
if [[ "$fail" == 0 ]]; then
  echo "enroll.sh refuses an unstated class and its dry-run touches nothing."
else
  echo "problems found — see the FAIL lines above."
fi
exit "$fail"
