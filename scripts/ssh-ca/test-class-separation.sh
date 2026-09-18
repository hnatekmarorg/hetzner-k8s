#!/usr/bin/env bash
#
# test-class-separation.sh — prove the SSH CA class model actually holds, without OpenBao.
#
# Creates two CAs locally (the infra CA and the dev CA, exactly as the two OpenBao mounts
# do), signs admin certificates from each, starts one throwaway sshd per class on
# 127.0.0.1 (high ports, own config + host keys, nothing under /etc/ssh is touched) and
# asserts the full accept/reject matrix:
#
#   1  infra cert -> infra host   ALLOW     the class works at all
#   2  infra cert -> dev host     DENY      a class certificate has no authority elsewhere
#   3  dev   cert -> dev host     ALLOW     symmetric
#   4  dev   cert -> infra host   DENY      the case that must never regress
#   5  bare key, no cert          DENY      certificate auth, not static keys
#   6  cert, principal `viewer`   DENY      the tier gate (AuthorizedPrincipalsFile)
#   7  cert, principal `admin`, no principals file   DENY   fails closed
#   8  host trusts BOTH CAs       ALLOW     the misconfiguration this model must prevent
#
# Case 8 is the point: it is what a single shared CA would look like, and it is the state
# `enroll.sh verify` refuses to leave behind.
#
# Usage: test-class-separation.sh [--user <unix-user>] [--port-base 2222] [--keep]
# Requires: ssh-keygen, sshd, ssh, ssh-keyscan-free (uses StrictHostKeyChecking=no).
#
set -euo pipefail

USER_TARGET="$(id -un)"
PORT_BASE=2222
KEEP=0
WORKDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)      USER_TARGET="${2:-}"; shift 2 ;;
    --port-base) PORT_BASE="${2:-}"; shift 2 ;;
    --workdir)   WORKDIR="${2:-}"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v sshd >/dev/null || { echo "sshd not found" >&2; exit 2; }
id "$USER_TARGET" >/dev/null 2>&1 || { echo "no such unix user: $USER_TARGET" >&2; exit 2; }

WORKDIR="${WORKDIR:-$(mktemp -d /tmp/ssh-ca-test.XXXXXX)}"
INFRA_PORT=$((PORT_BASE))
DEV_PORT=$((PORT_BASE + 1))
BOTH_PORT=$((PORT_BASE + 2))
PIDS=()

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  if [[ "$KEEP" == 1 ]]; then
    echo "artifacts kept in $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

# ------------------------------------------------------------------ CAs and certificates

ssh-keygen -q -t ed25519 -N '' -C 'infra-ca' -f "$WORKDIR/ca_infra"
ssh-keygen -q -t ed25519 -N '' -C 'dev-ca'   -f "$WORKDIR/ca_dev"

# keys: one per role, one per class
ssh-keygen -q -t ed25519 -N '' -C 'infra-host' -f "$WORKDIR/key_infra"
ssh-keygen -q -t ed25519 -N '' -C 'dev-host'   -f "$WORKDIR/key_dev"
ssh-keygen -q -t ed25519 -N '' -C 'viewer'     -f "$WORKDIR/key_viewer"

sign() {  # <ca> <key> <principals> <outfile>
  ssh-keygen -q -s "$1" -I "$(basename "$2"):$3" -n "$3" -V -5m:+10m "$2.pub" >/dev/null 2>&1
  mv "$2-cert.pub" "$4"
  printf '%s\n' "$4"
}

CERT_INFRA="$(sign "$WORKDIR/ca_infra" "$WORKDIR/key_infra"  admin  "$WORKDIR/cert_infra.pub")"
CERT_DEV="$(sign "$WORKDIR/ca_dev"     "$WORKDIR/key_dev"    admin  "$WORKDIR/cert_dev.pub")"
CERT_VIEWER="$(sign "$WORKDIR/ca_dev"  "$WORKDIR/key_viewer" viewer "$WORKDIR/cert_viewer.pub")"

# Case 9: a certificate that is correct in every other way, but pinned to a source range
# the client is not in — this is the `source-address` critical option the class roles set
# via default_critical_options. If ssh-keygen refuses -O source-address for a user
# certificate, the case is reported as skipped rather than silently passing.
CERT_ELSEWHERE=""
if ssh-keygen -q -s "$WORKDIR/ca_infra" -I "key_infra:elsewhere" -n admin \
     -O source-address=10.0.0.0/8 -V -5m:+10m "$WORKDIR/key_infra.pub" >/dev/null 2>&1; then
  mv "$WORKDIR/key_infra-cert.pub" "$WORKDIR/cert_elsewhere.pub"
  CERT_ELSEWHERE="$WORKDIR/cert_elsewhere.pub"
fi

# ---------------------------------------------------------------- principals (tier gate)

mkdir -p "$WORKDIR/principals" "$WORKDIR/principals_empty"
echo admin > "$WORKDIR/principals/$USER_TARGET"      # infra + dev hosts: admin tier only
# principals_empty stays empty on purpose (case 8: the gate must fail closed)
# authorized_keys/ is deliberately never created: static-key login must not be possible.

# ------------------------------------------------------------------------- sshd configs

start_sshd() {  # <name> <port> <ca-file> <principals-dir>
  local name="$1" port="$2" ca="$3" princ="$4"
  ssh-keygen -q -t ed25519 -N '' -f "$WORKDIR/hostkey_$name"
  cat >"$WORKDIR/sshd_$name.conf" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $WORKDIR/hostkey_$name
PidFile $WORKDIR/sshd_$name.pid
LogLevel VERBOSE
TrustedUserCAKeys $ca
AuthorizedPrincipalsFile $princ/%u
AuthorizedKeysFile $WORKDIR/authorized_keys/%u
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowUsers $USER_TARGET
EOF
  /usr/sbin/sshd -f "$WORKDIR/sshd_$name.conf" -E "$WORKDIR/sshd_$name.log" -D &
  PIDS+=($!)
  local i
  for i in $(seq 1 40); do
    (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null && { exec 3<&- 3>&-; return 0; }
    sleep 0.25
  done
  echo "sshd '$name' did not come up on port $port" >&2
  sed 's/^/    sshd: /' "$WORKDIR/sshd_$name.log" >&2 || true
  exit 3
}

start_sshd infra "$INFRA_PORT" "$WORKDIR/ca_infra.pub" "$WORKDIR/principals"
start_sshd dev   "$DEV_PORT"   "$WORKDIR/ca_dev.pub"   "$WORKDIR/principals"
# The misconfiguration in one line: a host that trusts both classes' CAs.
cat "$WORKDIR/ca_infra.pub" "$WORKDIR/ca_dev.pub" > "$WORKDIR/ca_both.pub"
start_sshd both  "$BOTH_PORT"  "$WORKDIR/ca_both.pub"  "$WORKDIR/principals"
# A host whose tier gate is empty: the certificate must still be refused (case 8).
start_sshd noprinc "$((PORT_BASE + 3))" "$WORKDIR/ca_infra.pub" "$WORKDIR/principals_empty"

# ---------------------------------------------------------------------------- the matrix
#
# Each probe asserts AUTHENTICATION, not a remote command: `ssh -N` opens the session and
# keeps it open, so exit 124 (killed by timeout) means the certificate was accepted and
# 255 means it was refused. Probing with a real command instead would make the result
# depend on the test sshd's SELinux domain being able to exec the user's shell, which is
# a property of the host running the test, not of the model under test.

PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"

probe() {  # <port> <key> [cert] -> sets PROBE_RC
  local port="$1" key="$2" cert="${3:-}"
  local -a args=(-p "$port" -i "$key" -N -o BatchMode=yes -o IdentitiesOnly=yes
                 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                 -o PreferredAuthentications=publickey -o ConnectTimeout=5)
  [[ -n "$cert" ]] && args+=(-o "CertificateFile=$cert")
  set +e
  timeout "$PROBE_TIMEOUT" ssh "${args[@]}" "$USER_TARGET@127.0.0.1" \
    >/dev/null 2>"$WORKDIR/.attempt.err"
  PROBE_RC=$?
  set -e
}

expect() {  # <allow|deny> <description> <sshd-log> <port> <key> [cert]
  local want="$1" desc="$2" log="$3"; shift 3
  local before lines accepted
  before=$(wc -l <"$log" 2>/dev/null || echo 0)
  probe "$@"
  lines=$(tail -n "+$((before + 1))" "$log" 2>/dev/null || true)
  grep -q "Accepted publickey for" <<<"$lines" && accepted=1 || accepted=0

  if [[ "$want" == allow ]]; then
    if [[ "$PROBE_RC" == 124 && "$accepted" == 1 ]]; then
      ok "$desc — accepted (session held open; sshd logged the certificate)"
    else
      bad "$desc — expected accept, probe rc=$PROBE_RC, sshd-accepted=$accepted"
      sed 's/^/          client: /' "$WORKDIR/.attempt.err" | tail -3
      sed 's/^/          sshd:   /' <<<"$lines" | tail -3
    fi
  else
    # A refusal has to come from the certificate check, not from a dead socket or a typo.
    if [[ "$accepted" == 0 && "$PROBE_RC" != 124 ]]; then
      if grep -qE "Failed publickey|Certificate invalid|no matching principal|not permitted" <<<"$lines"; then
        ok "$desc — refused by the authentication path"
      else
        bad "$desc — refused, but not by an authentication decision (probe rc=$PROBE_RC)"
        sed 's/^/          sshd:   /' <<<"$lines" | tail -3
      fi
    else
      bad "$desc — expected refusal, probe rc=$PROBE_RC, sshd-accepted=$accepted"
      sed 's/^/          sshd:   /' <<<"$lines" | tail -3
    fi
  fi
}

echo "class separation matrix (user: $USER_TARGET, ports: $INFRA_PORT/$DEV_PORT/$BOTH_PORT/$((PORT_BASE + 3)))"
expect allow "1 infra cert  -> infra host"               "$WORKDIR/sshd_infra.log" "$INFRA_PORT" "$WORKDIR/key_infra"  "$CERT_INFRA"
expect deny  "2 infra cert  -> dev host"                 "$WORKDIR/sshd_dev.log"   "$DEV_PORT"   "$WORKDIR/key_infra"  "$CERT_INFRA"
expect allow "3 dev   cert  -> dev host"                 "$WORKDIR/sshd_dev.log"   "$DEV_PORT"   "$WORKDIR/key_dev"    "$CERT_DEV"
expect deny  "4 dev   cert  -> infra host"               "$WORKDIR/sshd_infra.log" "$INFRA_PORT" "$WORKDIR/key_dev"    "$CERT_DEV"
expect deny  "5 bare key, no cert -> infra host"         "$WORKDIR/sshd_infra.log" "$INFRA_PORT" "$WORKDIR/key_infra"  ""
expect deny  "6 principal 'viewer' -> infra host"        "$WORKDIR/sshd_infra.log" "$INFRA_PORT" "$WORKDIR/key_viewer" "$CERT_VIEWER"
expect allow "7 infra cert -> host trusting BOTH CAs"    "$WORKDIR/sshd_both.log"  "$BOTH_PORT"  "$WORKDIR/key_infra"  "$CERT_INFRA"

# 8: the tier gate is what makes a class certificate sufficient. Without the target unix
# user's principals file the login must fail closed, not fall through to the CA alone.
expect deny  "8 infra cert -> host with no principals file" "$WORKDIR/sshd_noprinc.log" "$((PORT_BASE + 3))" "$WORKDIR/key_infra" "$CERT_INFRA"

# 9: sshd enforces the certificate's source-address pin, which is the mechanism the class
# roles use (default_critical_options) to keep certificates inside the estate's nets.
if [[ -n "$CERT_ELSEWHERE" ]]; then
  expect deny "9 infra cert pinned to 10.0.0.0/8 -> infra host from 127.0.0.1" \
    "$WORKDIR/sshd_infra.log" "$INFRA_PORT" "$WORKDIR/key_infra" "$CERT_ELSEWHERE"
else
  printf '  \033[33mSKIP\033[0m  case 9: this ssh-keygen will not put source-address on a user certificate\n'
fi

echo
echo "note: case 7 is the state a single shared CA would produce — every class certificate"
echo "      works on every host. It is what 'enroll.sh verify' refuses to leave behind."


if [[ "$fail" == 0 ]]; then
  printf '\nall cases behaved as designed: the class is enforced by the CA, the tier by the principals file.\n'
else
  printf '\nmodel violated — see the FAIL lines above.\n'
fi
exit "$fail"

