#!/usr/bin/env bash
#
# enroll.sh — give THIS host one of the two SSH CA classes.
#
# Same two-axis model as the Kubernetes clusters (see devops-cluster
# charts/cluster-base/templates/rbac/cluster-access.yaml, clusterClass: dev|infra):
# the class is an explicit input that is never guessed, and it decides both the trust
# anchor the host accepts and the signing path the host uses.
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
#   trust    install the class trust anchor + sshd certificate-auth config (no secrets)
#   issue    mint and install THIS host's admin certificate: the machine's own identity
#   verify   re-check what is installed and what sshd actually resolves
#   status   print the installed certificate (ssh-keygen -L) and the effective sshd config
#
# Examples:
#   enroll.sh --class infra trust          # balteus trusts the infra CA only
#   enroll.sh --class infra issue          # balteus gets its infra admin certificate
#   enroll.sh --class dev trust --dry-run  # print the changes for a sandbox host
#
# OpenBao credentials: BAO_TOKEN / VAULT_TOKEN in the environment, or the CLI's own
# ~/.vault-token fallback. Machines should carry a class-scoped token (policy
# hnatekmarorg-ssh-class-<class>), never the human admin token.
#
set -euo pipefail

# ---------------------------------------------------------------------------- defaults

BAO_ADDR="${BAO_ADDR:-${VAULT_ADDR:-https://bao.hnatekmar.xyz}}"
MOUNT_PREFIX="hnatekmarorg-ssh"
TIER="admin"                      # certificate principal; the class is the CA
UNIX_USERS=("root")               # unix logins the certificate may be used for
SSH_DIR="/etc/ssh"
PRINCIPALS_DIR="${SSH_DIR}/auth_principals"
CLIENT_DIR="${SSH_DIR}/openbao-client"
RENEW_DAYS="${RENEW_DAYS:-1}"     # cert ttl requested at issuance
CLASS=""
COMMAND=""
DRY_RUN=0

# ------------------------------------------------------------------------------ helpers

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
    rm -f "$tmp"
    log "  unchanged: $path"
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] would write $path (mode $mode):"
    sed 's/^/    | /' "$tmp" >&2
    rm -f "$tmp"
    return 0
  fi
  # cert auth requires the target user to be able to read what sshd reads; the file is
  # root-owned and world-readable, so sshd (root) and the target user both can.
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log "  wrote: $path"
}

sshd_unit() {
  # NOTE: `systemctl ... | grep -q` would be wrong here — grep exits on first match, systemd
  # gets SIGPIPE, and with `set -o pipefail` the pipeline reports failure even though grep
  # found the unit. Capture the list first, then match.
  local units
  units="$(systemctl list-unit-files 2>/dev/null || true)"
  if grep -qE '^sshd\.service' <<<"$units"; then printf 'sshd'; else printf 'ssh'; fi
}

reload_sshd() {
  local unit; unit="$(sshd_unit)"
  if have systemctl && systemctl is-active --quiet "$unit"; then
    run systemctl reload "$unit" || log "  warning: reload of $unit failed; reload it by hand"
  else
    log "  note: $unit not running here — reload it yourself before testing"
  fi
}

bao_cli() {
  if have bao; then printf 'bao'; elif have vault; then printf 'vault'; else die "neither bao nor vault CLI found"; fi
}

bao_read() {                      # <path> [field]
  local path="$1" field="${2:-}"
  local cli; cli="$(bao_cli)"
  if [[ -n "$field" ]]; then
    BAO_ADDR="$BAO_ADDR" "$cli" read -field="$field" "$path"
  else
    BAO_ADDR="$BAO_ADDR" "$cli" read "$path"
  fi
}

# --------------------------------------------------------------------------- arguments

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)     CLASS="${2:-}"; shift 2 ;;
    --class=*)   CLASS="${1#*=}"; shift ;;
    --user)      UNIX_USERS+=("${2:-}"); shift 2 ;;
    --user=*)    UNIX_USERS+=("${1#*=}"); shift ;;
    --tier)      TIER="${2:-}"; shift 2 ;;
    --tier=*)    TIER="${1#*=}"; shift ;;
    --renew-days) RENEW_DAYS="${2:-}"; shift 2 ;;
    --renew-days=*) RENEW_DAYS="${1#*=}"; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --help|-h)   usage 0 ;;
    trust|issue|verify|status)
                 [[ -n "$COMMAND" ]] && die "only one command at a time"
                 COMMAND="$1"; shift ;;
    *)           die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$COMMAND" ]] || usage 1
[[ -n "$CLASS" ]] || die "class is required: --class infra|dev — refusing to guess, since guessing wrong trusts the wrong CA"

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
CLIENT_KEY="${CLIENT_DIR}/id_ed25519"
CLIENT_CERT="${CLIENT_KEY}-cert.pub"
CLIENT_CONF="${SSH_DIR}/ssh_config.d/20-openbao-${CLASS}-client.conf"

require_root() { [[ "$(id -u)" == 0 ]] || die "$COMMAND requires root (writes ${SSH_DIR})"; }

# ------------------------------------------------------------------------ trust anchor

cmd_trust() {
  require_root
  log "class: ${CLASS}  ->  CA mount ${MOUNT}, trust anchor ${CA_FILE}"

  log "fetching the ${CLASS} class CA public key from OpenBao"
  local pub
  pub="$(bao_read "${MOUNT}/config/ca" public_key)" \
    || die "could not read ${MOUNT}/config/ca — is the class provisioned, and does this token carry policy hnatekmarorg-ssh-class-${CLASS}?"
  [[ "$pub" == ssh-* ]] || die "unexpected public key from OpenBao: ${pub:0:24}..."

  printf '%s\n' "$pub" | write_file_if_changed "$CA_FILE" 0644

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
AuthorizedPrincipalsFile ${PRINCIPALS_DIR}/%u
#
# Static authorized_keys stay enabled on purpose: the break-glass window closes by
# removing keys from the hosts, not by disabling this host's ability to accept them.
EOF

  local user
  for user in "${UNIX_USERS[@]}"; do
    id "$user" >/dev/null 2>&1 || die "no such unix user: $user"
    printf '%s\n' "$TIER" | write_file_if_changed "${PRINCIPALS_DIR}/${user}" 0644
  done

  ensure_dropin_included
  reload_sshd
  log "done — verify with: $0 --class ${CLASS} verify"
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

# ---------------------------------------------------------------- machine certificate

cmd_issue() {
  require_root
  if [[ ! -f "$CA_FILE" ]]; then
    if [[ "$DRY_RUN" == 1 ]]; then
      log "  [dry-run] no trust anchor at ${CA_FILE} yet (the 'trust' step would write it); continuing"
    else
      die "no trust anchor installed — run '$0 --class ${CLASS} trust' first"
    fi
  fi

  if [[ -f "$CLIENT_KEY" ]]; then
    log "reusing existing machine key ${CLIENT_KEY}"
  else
    log "generating machine key ${CLIENT_KEY}"
    if [[ "$DRY_RUN" == 1 ]]; then
      log "  [dry-run] ssh-keygen -t ed25519 -N '' -C 'openbao-${CLASS}@$(hostname -f)' -f ${CLIENT_KEY}"
    else
      install -d -m 0755 "$CLIENT_DIR"
      ssh-keygen -q -t ed25519 -N '' -C "openbao-${CLASS}@$(hostname -f)" -f "$CLIENT_KEY"
      chmod 0600 "$CLIENT_KEY"; chmod 0644 "${CLIENT_KEY}.pub"
    fi
  fi

  log "signing the ${CLASS}-class admin certificate (ttl ${RENEW_DAYS}d)"
  # valid_principals is passed explicitly: the role's allowed_users is exactly [admin],
  # so the certificate shape is the same however it is signed.
  local cli signed
  cli="$(bao_cli)"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "  [dry-run] ${cli} write -field=signed_key ${MOUNT}/sign/${TIER} public_key=@${CLIENT_KEY}.pub valid_principals=${TIER} cert_type=user key_id=${CLASS}:$(hostname -f) ttl=${RENEW_DAYS}d"
    return 0
  fi
  signed="$(BAO_ADDR="$BAO_ADDR" "$cli" write -field=signed_key "${MOUNT}/sign/${TIER}" \
      public_key="@${CLIENT_KEY}.pub" \
      valid_principals="$TIER" \
      cert_type=user \
      key_id="${CLASS}:$(hostname -f)" \
      ttl="${RENEW_DAYS}d")" \
    || die "signing failed — does this token carry policy hnatekmarorg-ssh-class-${CLASS}?"
  [[ "$signed" == ssh-ed25519-cert-v01* || "$signed" == ssh-*-cert-v01* ]] \
    || die "unexpected certificate from OpenBao: ${signed:0:24}..."
  printf '%s\n' "$signed" | write_file_if_changed "$CLIENT_CERT" 0644

  # Outbound side. IdentityFile/CertificateFile are offered; IdentitiesOnly is NOT set,
  # because on an existing host that would break every other key this box uses. Setting
  # IdentitiesOnly=yes is the hardening step once static keys are stripped.
  log "installing the outbound ssh client config"
  write_file_if_changed "$CLIENT_CONF" 0644 <<EOF
# Managed by scripts/ssh-ca/enroll.sh (hetzner-k8s) — class: ${CLASS}
# This host's own identity: a ${CLASS}-class certificate signed by the ${CLASS} CA.
# IdentityFile / CertificateFile are used with any explicit \`ssh -i\` too.
IdentityFile ${CLIENT_KEY}
CertificateFile ${CLIENT_CERT}
EOF

  log "done — this host now holds the ${CLASS} class certificate:"
  cmd_status
}

# ----------------------------------------------------------------------------- verify

cmd_verify() {
  require_root
  local rc=0 other_ca="${SSH_DIR}/ssh_ca_${OTHER_CLASS}.pub"

  log "class under test: ${CLASS} (other class: ${OTHER_CLASS})"

  if [[ -f "$CA_FILE" ]]; then
    log "  ok      trust anchor present: ${CA_FILE} ($(ssh-keygen -lf "$CA_FILE" | awk '{print $2}'))"
  else
    log "  MISSING trust anchor: ${CA_FILE}"; rc=1
  fi

  if have sshd; then
    local effective
    effective="$(sshd -T 2>/dev/null | grep -i '^trustedusercakeys' || true)"
    log "  sshd resolves: ${effective:-<none>}"
    if grep -q "${CA_FILE}" <<<"$effective"; then
      log "  ok      sshd trusts the ${CLASS} CA"
    else
      log "  FAIL    sshd does not trust ${CA_FILE} — the drop-in is not being read"; rc=1
    fi
    # The misconfiguration that would silently merge the two classes.
    if [[ -f "$other_ca" ]] && grep -q "${other_ca}" <<<"$effective"; then
      log "  FAIL    sshd also trusts the ${OTHER_CLASS} CA (${other_ca}) — classes are not separated"; rc=1
    fi
    local p; p="$(sshd -T 2>/dev/null | grep -i '^authorizedprincipalsfile' || true)"
    [[ -n "$p" ]] && log "  ok      tier gate: ${p}" || { log "  FAIL    no AuthorizedPrincipalsFile — the tier gate is missing"; rc=1; }
  fi

  local user
  for user in "${UNIX_USERS[@]}"; do
    if [[ -f "${PRINCIPALS_DIR}/${user}" ]]; then
      log "  ok      ${user} accepts principal(s): $(tr '\n' ' ' <"${PRINCIPALS_DIR}/${user}")"
    else
      log "  FAIL    ${PRINCIPALS_DIR}/${user} is missing — certificate logins fail closed"; rc=1
    fi
  done

  if [[ -f "$CLIENT_CERT" ]]; then
    log "  ok      machine certificate present:"
    ssh-keygen -L -f "$CLIENT_CERT" | sed -n '1,12p' | sed 's/^/          /' >&2
  else
    log "  note    no machine certificate yet (run: $0 --class ${CLASS} issue)"
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
  trust)  cmd_trust ;;
  issue)  cmd_issue ;;
  verify) cmd_verify ;;
  status) cmd_status ;;
esac
