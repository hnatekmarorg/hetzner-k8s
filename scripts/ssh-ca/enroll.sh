#!/usr/bin/env bash
#
# enroll.sh — give THIS machine one of the two SSH CA classes.
#
# Same two-axis model as the Kubernetes clusters (devops-cluster
# charts/cluster-base, clusterClass: dev|infra): the class is an explicit input that is
# never guessed, and it decides both the trust anchor the host accepts and the signing
# path the machine uses.
#
#   infra   servers that must keep working   — balteus, TrueNAS, github runner, keepers
#   dev     sandboxes, free to break         — kubernetes-sandbox (VM 133)
#
# The classes are two separate CAs in OpenBao (hnatekmarorg-ssh-infra / -dev), so the
# isolation is structural rather than a rule someone has to remember: an infra host
# trusts only the infra CA's public key, and a dev-class certificate cannot authenticate
# there at all. This script never installs both.
#
# The certificate's principal carries the TIER (`admin`), not the class — the class is
# already the CA that signed it. sshd's AuthorizedPrincipalsFile is what turns the tier
# into a gate, and it is required: OpenBao issues the cert with principals = [admin], so
# login as any unix user is refused unless that user's principals file lists `admin`.
#
# Commands:
#   issue      (default) mint THIS machine's admin certificate + install the client config
#   trust      install the class trust anchor + sshd certificate-auth config (needs root)
#   verify     re-check what is installed and what sshd actually resolves
#   status     print the installed certificate (and the effective sshd config, if root)
#
# Examples:
#   bash enroll.sh dev                    # container/CI: this machine gets a dev cert
#   enroll.sh --class infra trust         # balteus trusts the infra CA only
#   enroll.sh --class infra trust --no-reload
#   bash enroll.sh dev issue --dry-run    # print the changes, write nothing
#   bash enroll.sh --check-hash           # verify this file against its published sha256
#
# Dependencies: bash, ssh-keygen, and curl (or wget). No OpenBao CLI, no systemd, no
# root — `issue` is designed to run as an unprivileged user inside a container:
#
#   RUN curl -fsSLo /tmp/enroll.sh  "$RAW/scripts/ssh-ca/enroll.sh"        && \
#       curl -fsSLo /tmp/enroll.sh.sha256 "$RAW/scripts/ssh-ca/enroll.sh.sha256" && \
#       (cd /tmp && sha256sum -c enroll.sh.sha256)                        && \
#       bash /tmp/enroll.sh dev --ttl 168h
#
# (pin $RAW to a commit, not to main, and pass the token through a BuildKit secret —
#  a token in a RUN line or an ARG ends up in the image history.)
#
# OpenBao credentials: BAO_TOKEN / VAULT_TOKEN, or --token, or ~/.vault-token (the file
# `bao login` writes). Machines should carry a class-scoped token (policy
# hnatekmarorg-ssh-class-<class>), never the human admin token.
#
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------- defaults

BAO_ADDR="${BAO_ADDR:-${VAULT_ADDR:-https://bao.hnatekmar.xyz}}"
MOUNT_PREFIX="hnatekmarorg-ssh"
TIER="admin"                      # certificate principal; the class is the CA
UNIX_USERS=("root")               # host mode: unix logins the certificate may be used for
TTL="${TTL:-24h}"                 # 24h default, role max 168h
SSH_DIR="/etc/ssh"                # host mode (root): trust anchor + sshd config
PRINCIPALS_SUBDIR="auth_principals"
CLIENT_PREFIX="${CLIENT_PREFIX:-${HOME:-/root}/.ssh/openbao}"
TOKEN="${BAO_TOKEN:-${VAULT_TOKEN:-}}"
CLASS=""
COMMAND=""
DRY_RUN=0
NO_RELOAD=0
CHECK_HASH=0

# ------------------------------------------------------------------------------ helpers

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '3,45p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '  [dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

write_file_if_changed() {         # <path> <mode> ; content on stdin
  local path="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; log "  unchanged: $path"; return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] would write $path (mode $mode):"
    sed 's/^/    | /' "$tmp" >&2
    rm -f "$tmp"; return 0
  fi
  mkdir -p "$(dirname "$path")"
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log "  wrote: $path"
}

# In a container there is no systemd and usually no sshd: the client half must not care.
in_container() { [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] || grep -qaE '(docker|containerd|podman|kubepods)' /proc/1/cgroup 2>/dev/null; }

sshd_unit() {
  # systemctl ... | grep -q would be wrong: grep exits on first match, systemd gets
  # SIGPIPE, and with `set -o pipefail` the pipeline reports failure despite the match.
  local units
  have systemctl || { printf ''; return 0; }
  units="$(systemctl list-unit-files 2>/dev/null || true)"
  if grep -qE '^sshd\.service' <<<"$units"; then printf 'sshd'; else printf 'ssh'; fi
}

reload_sshd() {
  local unit
  unit="$(sshd_unit)"
  if [[ "$NO_RELOAD" == 1 ]]; then
    log "  --no-reload: sshd not reloaded; do it yourself (systemctl reload ${unit:-sshd})"
    return 0
  fi
  if [[ -z "$unit" ]] || in_container; then
    log "  no systemd here (container): wrote the config, nothing to reload"
    return 0
  fi
  if have systemctl && systemctl is-active --quiet "$unit"; then
    run systemctl reload "$unit" || log "  warning: reload of $unit failed; reload it by hand"
  else
    log "  note: $unit not running here — reload it yourself before testing"
  fi
}

# ------------------------------------------------------------------------- HTTP (no CLI)

http_tool() {
  if have curl; then printf 'curl'; elif have wget; then printf 'wget'; else die "neither curl nor wget found"; fi
}

resolve_token() {
  if [[ -n "$TOKEN" ]]; then return 0; fi
  local f="${HOME:-/root}/.vault-token"
  if [[ -f "$f" ]]; then TOKEN="$(tr -d '\n' <"$f")"; return 0; fi
  die "no OpenBao token: set BAO_TOKEN, pass --token, or log in first (bao login writes ~/.vault-token)"
}

# <path> <json-body-or-empty> <outfile> -> body written to <outfile>, status in $HTTP_CODE.
# NOTE: the body is written to a file and the status to a global on purpose — returning the
# body on stdout would put the caller in a subshell and lose HTTP_CODE with it.
http_to() {
  local path="$1" body="${2:-}" out="$3" tool code
  tool="$(http_tool)"
  resolve_token
  if [[ "$tool" == curl ]]; then
    if [[ -n "$body" ]]; then
      code="$(printf '%s' "$body" | curl -sS -o "$out" -w '%{http_code}' \
        -X POST -H "X-Vault-Token: ${TOKEN}" -H 'Content-Type: application/json' \
        --data-binary @- "${BAO_ADDR%/}/v1/${path#/}" 2>/dev/null)" || true
    else
      code="$(curl -sS -o "$out" -w '%{http_code}' -H "X-Vault-Token: ${TOKEN}" \
        "${BAO_ADDR%/}/v1/${path#/}" 2>/dev/null)" || true
    fi
  else
    if [[ -n "$body" ]]; then
      code="$(printf '%s' "$body" | wget -q -O "$out" --server-response \
        --header="X-Vault-Token: ${TOKEN}" --header='Content-Type: application/json' \
        --post-file=- "${BAO_ADDR%/}/v1/${path#/}" 2>&1 | awk '/HTTP\//{c=$2} END{print c}')" || true
    else
      code="$(wget -q -O "$out" --server-response --header="X-Vault-Token: ${TOKEN}" \
        "${BAO_ADDR%/}/v1/${path#/}" 2>&1 | awk '/HTTP\//{c=$2} END{print c}')" || true
    fi
  fi
  HTTP_CODE="${code:-000}"
}

# Extract a string field without jq/python, for SINGLE-LINE key material.
# Two details that matter: OpenBao JSON-escapes the newline it appends to key material as
# `\n`, and a certificate carrying a literal `\n` is rejected by ssh-keygen ("invalid
# format") — so the escapes are decoded and the result trimmed to one line.
json_key_field() {  # <field> ; JSON on stdin
  sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1 \
    | sed -e 's/\\n/\n/g' -e 's/\\r//g' -e 's/\\t/ /g' -e 's|\\/|/|g' -e 's/\\"/"/g' \
    | tr -d '\n' | sed 's/[[:space:]]*$//'
}

api_error() {  # body
  local msg
  msg="$(printf '%s' "$1" | sed -n 's/.*"errors":\["\([^"]*\)".*/\1/p' | head -1)"
  printf '%s' "${msg:-no error detail returned}"
}

fetch_ca_pubkey() {  # <mount> <outfile>
  http_to "${1}/config/ca" "" "$2"
  [[ "$HTTP_CODE" == 200 ]] || die "could not read ${1}/config/ca (HTTP $HTTP_CODE: $(api_error "$(cat "$2")")) — is the class provisioned, and does this token carry read on config/ca?"
  json_key_field public_key <"$2"
}

sign_cert() {  # <mount> <pubkey> <outfile>
  local body
  body="{\"public_key\":\"$2\",\"valid_principals\":\"${TIER}\",\"cert_type\":\"user\",\"key_id\":\"${CLASS}:$(hostname -f 2>/dev/null || hostname)\",\"ttl\":\"${TTL}\"}"
  http_to "${1}/sign/${TIER}" "$body" "$3"
  [[ "$HTTP_CODE" == 200 ]] || die "signing failed (HTTP $HTTP_CODE: $(api_error "$(cat "$3")")) — does this token carry policy hnatekmarorg-ssh-class-${CLASS}?"
  json_key_field signed_key <"$3"
}

# Parse before installing. A certificate ssh-keygen cannot read is worse than no
# certificate: it looks installed and fails at connect time instead.
assert_parses() {  # <description> <key-material>
  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$2" >"$tmp"
  if ssh-keygen -L -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  die "$1 from OpenBao does not parse with this ssh-keygen (${#2} bytes) — refusing to install it"
}

# --------------------------------------------------------------------------- self-hash

check_hash() {
  local want="${ENROLL_EXPECT_SHA256:-}" got sibling
  got="$(sha256sum "$SCRIPT_PATH" | awk '{print $1}')"
  sibling="${SCRIPT_PATH}.sha256"
  [[ -z "$want" && -f "$sibling" ]] && want="$(awk '{print $1}' "$sibling")"
  if [[ -z "$want" ]]; then
    log "no expected hash (ENROLL_EXPECT_SHA256 unset, ${sibling} missing)."
    log "sha256 of this file: ${got}"
    return 0
  fi
  if [[ "$got" == "$want" ]]; then
    log "hash ok: ${got}"
    return 0
  fi
  die "hash mismatch: got ${got}, expected ${want} — do not run this file"
}

# --------------------------------------------------------------------------- arguments

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)     CLASS="${2:-}"; shift 2 ;;
    --class=*)   CLASS="${1#*=}"; shift ;;
    --token)     TOKEN="${2:-}"; shift 2 ;;
    --token=*)   TOKEN="${1#*=}"; shift ;;
    --ttl)       TTL="${2:-}"; shift 2 ;;
    --ttl=*)     TTL="${1#*=}"; shift ;;
    --prefix)    CLIENT_PREFIX="${2:-}"; shift 2 ;;
    --prefix=*)  CLIENT_PREFIX="${1#*=}"; shift ;;
    --user)      UNIX_USERS+=("${2:-}"); shift 2 ;;
    --user=*)    UNIX_USERS+=("${1#*=}"); shift ;;
    --tier)      TIER="${2:-}"; shift 2 ;;
    --tier=*)    TIER="${1#*=}"; shift ;;
    --no-reload) NO_RELOAD=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --check-hash) CHECK_HASH=1; shift ;;
    --help|-h)   usage 0 ;;
    -*)          die "unknown option: $1 (see --help)" ;;
    *)           POSITIONAL+=("$1"); shift ;;
  esac
done

[[ "$CHECK_HASH" == 1 ]] && { check_hash; exit $?; }

# Positional forms: `dev`, `dev issue`, `--class dev`.
for arg in "${POSITIONAL[@]:-}"; do
  case "$arg" in
    infra|dev) [[ -n "$CLASS" ]] && die "class given twice" || CLASS="$arg" ;;
    issue|trust|verify|status)
               [[ -n "$COMMAND" ]] && die "only one command at a time"
               COMMAND="$arg" ;;
    *)
      # A near-miss on the class deserves its own error: `Infra` must not read as a command,
      # and a first positional that is neither a command nor a class is most often a typo'd
      # class (`devl`) — say so instead of "unrecognised argument".
      if [[ "${arg,,}" == infra || "${arg,,}" == dev ]]; then
        die "class must be 'infra' or 'dev' (lowercase), got '$arg' — refusing to guess"
      fi
      if [[ -z "$CLASS" && -z "$COMMAND" ]]; then
        die "unrecognised argument: $arg — the class must be 'infra' or 'dev' (see --help)"
      fi
      die "unrecognised argument: $arg (see --help)" ;;
  esac
done
COMMAND="${COMMAND:-issue}"       # the container/CI path is the default one

[[ -n "$CLASS" ]] || die "class is required: infra|dev — refusing to guess, since guessing wrong trusts the wrong CA"

# The whole point of the model: a typo must not silently produce a host that trusts
# nothing, or (worse) the other class's key.
case "$CLASS" in
  infra|dev) ;;
  *) die "class must be 'infra' or 'dev', got '$CLASS' — refusing to guess" ;;
esac

MOUNT="${MOUNT_PREFIX}-${CLASS}"
CA_FILE="${SSH_DIR}/ssh_ca_${CLASS}.pub"
OTHER_CLASS=$([[ "$CLASS" == infra ]] && printf dev || printf infra)
SSHD_DROPIN="${SSH_DIR}/sshd_config.d/10-openbao-${CLASS}-ca.conf"
CLIENT_KEY="${CLIENT_PREFIX}/id_ed25519"
CLIENT_CERT="${CLIENT_KEY}-cert.pub"
CLIENT_CONF="${HOME:-/root}/.ssh/config.d/openbao-${CLASS}.conf"

require_root() { [[ "$(id -u)" == 0 ]] || die "$COMMAND needs root (writes ${SSH_DIR})"; }
have ssh-keygen || die "ssh-keygen not found (openssh-client)"

# ------------------------------------------------------------------- issue (client)

cmd_issue() {
  log "class: ${CLASS}  ->  CA mount ${MOUNT}, identity ${CLIENT_PREFIX}"

  if [[ -f "$CLIENT_KEY" ]]; then
    log "reusing existing machine key ${CLIENT_KEY}"
  else
    log "generating machine key ${CLIENT_KEY}"
    run mkdir -p "$CLIENT_PREFIX"
    run chmod 0700 "$CLIENT_PREFIX"
    run ssh-keygen -q -t ed25519 -N '' -C "openbao-${CLASS}@$(hostname -f 2>/dev/null || hostname)" -f "$CLIENT_KEY"
    [[ "$DRY_RUN" == 1 ]] || { chmod 0600 "$CLIENT_KEY"; chmod 0644 "${CLIENT_KEY}.pub"; }
  fi

  log "signing the ${CLASS}-class ${TIER} certificate (ttl ${TTL})"
  # valid_principals is passed explicitly: the role's allowed_users is exactly [admin],
  # so the certificate shape is the same however it is signed.
  local signed
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] POST ${BAO_ADDR%/}/v1/${MOUNT}/sign/${TIER} with valid_principals=${TIER} cert_type=user key_id=${CLASS}:$(hostname -f 2>/dev/null || hostname) ttl=${TTL}"
  else
    local j; j="$(mktemp)"
    signed="$(sign_cert "$MOUNT" "$(cat "${CLIENT_KEY}.pub")" "$j")" || { rm -f "$j"; exit 1; }
    [[ "$signed" == ssh-*-cert-v01* ]] || { rm -f "$j"; die "unexpected certificate from OpenBao: ${signed:0:24}..."; }
    rm -f "$j"
    assert_parses "the certificate" "$signed"
    printf '%s\n' "$signed" | write_file_if_changed "$CLIENT_CERT" 0644
  fi

  # The ssh client must pick this identity up. IdentityFile/CertificateFile are offered;
  # IdentitiesOnly is NOT set, because on an existing host that would break every other
  # key it uses. Setting it is the hardening step once static keys are stripped.
  log "wiring the identity into the ssh client config"
  write_file_if_changed "$CLIENT_CONF" 0644 <<EOF
# Managed by scripts/ssh-ca/enroll.sh (hetzner-k8s) — class: ${CLASS}
# This machine's own identity: a ${CLASS}-class certificate signed by the ${CLASS} CA.
# IdentityFile / CertificateFile still apply when \`ssh -i\` names another key.
IdentityFile ${CLIENT_KEY}
CertificateFile ${CLIENT_CERT}
EOF
  ensure_config_included

  log "done — this machine now holds the ${CLASS} class certificate"
  cmd_status
}

# An ssh_config drop-in is only read if the main config includes the directory (the same
# trap as Debian's sshd_config, which has no sshd_config.d include either).
ensure_config_included() {
  local main="${HOME:-/root}/.ssh/config"
  if [[ -f "$main" ]] && grep -qE "^[[:space:]]*Include[[:space:]]+.*${HOME:-/root}/\.ssh/config\.d/" "$main"; then
    log "  ${main} already includes ~/.ssh/config.d/"
    return 0
  fi
  log "  adding an Include for ~/.ssh/config.d/ to ${main}"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] would insert 'Include ${HOME:-/root}/.ssh/config.d/*.conf' at the top of ${main}"
    return 0
  fi
  mkdir -p "${HOME:-/root}/.ssh" "${HOME:-/root}/.ssh/config.d"
  chmod 0700 "${HOME:-/root}/.ssh"
  local tmp; tmp="$(mktemp)"
  {
    printf '# Managed by scripts/ssh-ca/enroll.sh — makes ~/.ssh/config.d/*.conf effective\n'
    printf 'Include %s/.ssh/config.d/*.conf\n\n' "${HOME:-/root}"
    [[ -f "$main" ]] && cat "$main"
  } >"$tmp"
  install -m 0600 -b "$tmp" "$main"       # -b keeps ~/.ssh/config~ as the undo
  rm -f "$tmp"
  log "  backup: ${main}~"
}

# ---------------------------------------------------------------- trust (host, root)

cmd_trust() {
  require_root
  log "class: ${CLASS}  ->  CA mount ${MOUNT}, trust anchor ${CA_FILE}"

  log "fetching the ${CLASS} class CA public key from OpenBao"
  local pub
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] GET ${BAO_ADDR%/}/v1/${MOUNT}/config/ca"
    pub="(not fetched in dry-run)"
  else
    local j; j="$(mktemp)"
    pub="$(fetch_ca_pubkey "$MOUNT" "$j")" || { rm -f "$j"; exit 1; }
    [[ "$pub" == ssh-* ]] || { rm -f "$j"; die "unexpected public key from OpenBao: ${pub:0:24}..."; }
    rm -f "$j"
    printf '%s\n' "$pub" | write_file_if_changed "$CA_FILE" 0644
  fi

  log "installing sshd certificate-auth config"
  write_file_if_changed "$SSHD_DROPIN" 0644 <<EOF
# Managed by scripts/ssh-ca/enroll.sh (hetzner-k8s) — class: ${CLASS}
#
# The class lives in this key: this host trusts the ${CLASS} CA and no other CA, so a
# ${OTHER_CLASS}-class certificate is not refused by policy here — it does not verify at all.
TrustedUserCAKeys ${CA_FILE}
#
# Tier gate. OpenBao issues class certificates with principals = [${TIER}], so a login is
# accepted only if the target unix user's principals file lists ${TIER}. Deleting these
# files fails closed; adding a principal here is what would widen the tier.
AuthorizedPrincipalsFile ${SSH_DIR}/${PRINCIPALS_SUBDIR}/%u
#
# Static authorized_keys stay enabled on purpose: the break-glass window closes by
# removing keys from the hosts, not by disabling this host's ability to accept them.
EOF

  local user
  for user in "${UNIX_USERS[@]}"; do
    id "$user" >/dev/null 2>&1 || die "no such unix user: $user"
    printf '%s\n' "$TIER" | write_file_if_changed "${SSH_DIR}/${PRINCIPALS_SUBDIR}/${user}" 0644
  done

  ensure_dropin_included
  reload_sshd
  log "done — verify with: $SCRIPT_PATH --class ${CLASS} verify"
}

# Debian's sshd_config has no sshd_config.d include by default (Proxmox hosts are Debian),
# so a drop-in that is never read would look installed and do nothing.
ensure_dropin_included() {
  local main="${SSH_DIR}/sshd_config"
  [[ -f "$main" ]] || { log "  note: no ${main}; not touching includes"; return 0; }
  if grep -qE "^[[:space:]]*Include[[:space:]]+${SSH_DIR}/sshd_config\.d/\*\.conf" "$main"; then
    log "  ${main} already includes ${SSH_DIR}/sshd_config.d/*.conf"
    return 0
  fi
  log "  adding the sshd_config.d include to ${main} (absent, so drop-ins would be dead files)"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] would insert 'Include ${SSH_DIR}/sshd_config.d/*.conf' at the top of ${main}"
    return 0
  fi
  local tmp; tmp="$(mktemp)"
  {
    printf '# Managed by scripts/ssh-ca/enroll.sh — makes sshd_config.d/*.conf effective\n'
    printf 'Include %s/sshd_config.d/*.conf\n\n' "$SSH_DIR"
    cat "$main"
  } >"$tmp"
  install -m 0644 -b "$tmp" "$main"       # -b keeps sshd_config~ as the undo
  rm -f "$tmp"
  log "  backup: ${main}~"
}

# ----------------------------------------------------------------------------- verify

cmd_verify() {
  local rc=0 other_ca="${SSH_DIR}/ssh_ca_${OTHER_CLASS}.pub"
  log "class under test: ${CLASS} (other class: ${OTHER_CLASS})"

  if [[ -f "$CA_FILE" ]]; then
    log "  ok      trust anchor present: ${CA_FILE} ($(ssh-keygen -lf "$CA_FILE" | awk '{print $2}'))"
  elif [[ "$(id -u)" == 0 ]]; then
    log "  note    no host trust anchor at ${CA_FILE} (this machine is a client only)"
  fi

  if have sshd && [[ "$(id -u)" == 0 ]]; then
    local effective
    effective="$(sshd -T 2>/dev/null | grep -i '^trustedusercakeys' || true)"
    log "  sshd resolves: ${effective:-<none>}"
    if [[ ! -f "$CA_FILE" && ! -f "$SSHD_DROPIN" ]]; then
      # client-only machine (container/CI): no host trust anchor was ever installed here,
      # so the absence of one is not a failure.
      log "  note    client-only machine — no host trust anchor installed, host checks skipped"
    elif grep -q "${CA_FILE}" <<<"$effective"; then
      log "  ok      sshd trusts the ${CLASS} CA"
    else
      log "  FAIL    sshd does not trust ${CA_FILE} — the drop-in is not being read"; rc=1
    fi
    if [[ -f "$other_ca" ]] && grep -q "${other_ca}" <<<"$effective"; then
      log "  FAIL    sshd also trusts the ${OTHER_CLASS} CA (${other_ca}) — classes are not separated"; rc=1
    fi
    local p; p="$(sshd -T 2>/dev/null | grep -i '^authorizedprincipalsfile' || true)"
    if [[ -f "$CA_FILE" || -f "$SSHD_DROPIN" ]]; then
      [[ -n "$p" ]] && log "  ok      tier gate: ${p}" || { log "  FAIL    no AuthorizedPrincipalsFile — the tier gate is missing"; rc=1; }
    fi
  elif [[ "$(id -u)" == 0 ]]; then
    log "  note    no sshd on this machine (container) — host-side checks skipped"
  fi

  local user
  for user in "${UNIX_USERS[@]}"; do
    if [[ -f "${SSH_DIR}/${PRINCIPALS_SUBDIR}/${user}" ]]; then
      log "  ok      ${user} accepts principal(s): $(tr '\n' ' ' <"${SSH_DIR}/${PRINCIPALS_SUBDIR}/${user}")"
    elif [[ "$(id -u)" == 0 && -f "$CA_FILE" ]]; then
      log "  FAIL    ${SSH_DIR}/${PRINCIPALS_SUBDIR}/${user} is missing — certificate logins fail closed"; rc=1
    fi
  done

  if [[ -f "$CLIENT_CERT" ]]; then
    log "  ok      machine certificate present:"
    ssh-keygen -L -f "$CLIENT_CERT" | sed -n '1,12p' | sed 's/^/          /' >&2
    # Is the client config actually wired where ssh will read it?
    if have ssh; then
      local eff
      eff="$(ssh -G -o BatchMode=yes example.invalid 2>/dev/null | grep -i '^certificatefile' || true)"
      if grep -q "${CLIENT_CERT}" <<<"$eff"; then
        log "  ok      ssh client resolves CertificateFile=${CLIENT_CERT}"
      else
        log "  note    ssh does not resolve this certificate (${eff:-no CertificateFile}); check the Include in ~/.ssh/config"
        log "          (ssh reads ~/.ssh/config from the password database, so a HOME that differs from your passwd entry needs: ssh -F \$HOME/.ssh/config)"
      fi
    fi
  else
    log "  note    no machine certificate at ${CLIENT_CERT} (run: $SCRIPT_PATH ${CLASS} issue)"
  fi

  [[ "$rc" == 0 ]] && log "verify: PASS" || log "verify: FAIL"
  return "$rc"
}

cmd_status() {
  if [[ -f "$CLIENT_CERT" ]]; then
    ssh-keygen -L -f "$CLIENT_CERT"
  else
    log "no certificate at ${CLIENT_CERT}"
  fi
  if have sshd && [[ "$(id -u)" == 0 ]]; then
    log "--- sshd ---"
    sshd -T 2>/dev/null | grep -iE '^(trustedusercakeys|authorizedprincipalsfile)' || true
  fi
}

case "$COMMAND" in
  issue)  cmd_issue ;;
  trust)  cmd_trust ;;
  verify) cmd_verify ;;
  status) cmd_status ;;
esac
