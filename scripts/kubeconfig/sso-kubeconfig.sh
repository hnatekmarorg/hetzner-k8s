#!/usr/bin/env bash
# ============================================================================
# sso-kubeconfig.sh — turn an admin kubeconfig into a credential-free SSO one
# ============================================================================
#
# WHAT IT DOES
# Reads a cluster entry (server + CA) from an existing kubeconfig and writes a new
# kubeconfig whose user authenticates through Keycloak with kubelogin. The output contains
# NO credential: no client certificate, no token, no secret. Only the API server address,
# its public CA, the issuer URL and a public client id. That is what makes it safe to keep
# around or hand to a teammate — access is decided by the identity they log in as, not by a
# key that was copied.
#
# WHAT IT DOES NOT DO
# It does not configure the cluster. kube-apiserver must already trust the issuer — see
# docs/kubeconfig-sso.md and scripts/kubeconfig/verify-oidc.sh.
#
# USAGE
#   ./sso-kubeconfig.sh --from ~/.kube/hetzner [options]
#
# OPTIONS
#   --from PATH          Source kubeconfig. Default: $KUBECONFIG or ~/.kube/config
#   --context NAME       Context in the source. Default: its current-context
#   --output PATH        Where to write. Default: ~/.kube/<cluster>-sso.yaml
#   --name NAME          Cluster name in the output. Default: as in the source
#   --issuer URL         OIDC issuer. Default: https://sso.hnatekmar.xyz/realms/master
#   --client-id ID       Public OIDC client. Default: kubectl-hnatekmar-xyz
#   --extra-scope SCOPE  Repeatable. Replaces the default (offline_access). offline_access is
#                        the default because it yields a refresh token, so kubelogin renews
#                        silently instead of sending the user to the browser every few minutes.
#   --stdout             Print the kubeconfig instead of writing a file.
#   --force              Overwrite an existing output file.
#   -h, --help           This text.
#
# EXAMPLES
#   ./sso-kubeconfig.sh --from ~/.kube/hetzner
#   ./sso-kubeconfig.sh --from ~/.kube/hetzner --context hetzner --output /tmp/k.yaml --stdout
#
# AFTERWARDS
#   kubectl --kubeconfig ~/.kube/hetzner-sso.yaml auth whoami
#   kubectl --kubeconfig ~/.kube/hetzner-sso.yaml auth can-i --list
#
# REQUIREMENTS
#   kubectl on PATH; kubelogin on the machine that will USE the kubeconfig
#   (brew install int128/kubelogin/kubelogin, or: go install github.com/int128/kubelogin@latest)
# ============================================================================

set -euo pipefail
umask 077

PROG="$(basename "$0")"
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
step() { printf '%s\n' "$*" >&2; }

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

FROM="${KUBECONFIG:-$HOME/.kube/config}"
SRC_CONTEXT=""
OUTPUT=""
CLUSTER_NAME=""
CONTEXT_NAME=""
ISSUER="https://sso.hnatekmar.xyz/realms/master"
CLIENT_ID="kubectl-hnatekmar-xyz"
SCOPES=("offline_access")
SCOPES_SET=0
TO_STDOUT=0
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from)        shift; FROM="${1:?--from needs a path}" ;;
    --context)     shift; SRC_CONTEXT="${1:?--context needs a name}" ;;
    --output|-o)   shift; OUTPUT="${1:?--output needs a path}" ;;
    --name)        shift; CLUSTER_NAME="${1:?--name needs a value}" ;;
    --context-name) shift; CONTEXT_NAME="${1:?--context-name needs a value}" ;;
    --issuer)      shift; ISSUER="${1:?--issuer needs a URL}" ;;
    --client-id)   shift; CLIENT_ID="${1:?--client-id needs a value}" ;;
    --extra-scope)
      # The first explicit scope replaces the default set; later ones append to it. Otherwise
      # `--extra-scope groups` would silently also request offline_access, which is not what the
      # caller asked for.
      shift
      if [ "$SCOPES_SET" -eq 0 ]; then SCOPES=(); SCOPES_SET=1; fi
      SCOPES+=("${1:?--extra-scope needs a value}")
      ;;
    --stdout)      TO_STDOUT=1 ;;
    --force|-f)    FORCE=1 ;;
    -h|--help)     usage 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             die "unexpected argument: $1 (try --help)" ;;
  esac
  shift
done

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
[ -f "$FROM" ] || die "source kubeconfig not found: $FROM"
case "$ISSUER" in
  https://*) ;;
  http://*)  warn "issuer is http:// — production issuers must be https://" ;;
  *)         die "--issuer must start with https:// (got: $ISSUER)" ;;
esac

# ---- resolve the source context --------------------------------------------
if [ -z "$SRC_CONTEXT" ]; then
  SRC_CONTEXT="$(kubectl --kubeconfig "$FROM" config current-context 2>/dev/null || true)"
  [ -n "$SRC_CONTEXT" ] || die "no current-context in $FROM and none given with --context"
fi
kubectl --kubeconfig "$FROM" config get-contexts -o name 2>/dev/null | grep -Fxq "$SRC_CONTEXT" \
  || die "context '$SRC_CONTEXT' does not exist in $FROM"

# ---- read the cluster entry -------------------------------------------------
# --minify + --context reduces the view to exactly this context's cluster, so the
# single-element jsonpath below is unambiguous even in a kubeconfig with many clusters.
q() { kubectl --kubeconfig "$FROM" config view --raw --minify --context "$SRC_CONTEXT" -o jsonpath="$1"; }

SRC_CLUSTER="$(q '{.clusters[0].name}')"
SERVER="$(q '{.clusters[0].cluster.server}')"
CA_DATA="$(q '{.clusters[0].cluster.certificate-authority-data}')"
CA_FILE="$(q '{.clusters[0].cluster.certificate-authority}')"
INSECURE="$(q '{.clusters[0].cluster.insecure-skip-tls-verify}')"

[ -n "$SERVER" ] || die "context '$SRC_CONTEXT' has no server"

# A CA given as a path is relative to the kubeconfig's directory, not the CWD.
if [ -z "$CA_DATA" ] && [ -n "$CA_FILE" ]; then
  [[ "$CA_FILE" = /* ]] || CA_FILE="$(cd "$(dirname "$FROM")" && pwd)/$CA_FILE"
  [ -f "$CA_FILE" ] || die "certificate-authority file referenced by the kubeconfig is missing: $CA_FILE"
  CA_DATA="$(base64 < "$CA_FILE" | tr -d '\n')"
fi
if [ -z "$CA_DATA" ] && [ "$INSECURE" != "true" ]; then
  die "cluster '$SRC_CLUSTER' has neither a CA nor insecure-skip-tls-verify; refusing to write a kubeconfig that cannot verify the API server"
fi

CLUSTER_NAME="${CLUSTER_NAME:-$SRC_CLUSTER}"
CONTEXT_NAME="${CONTEXT_NAME:-${CLUSTER_NAME}-sso}"
USER_NAME="sso-${CLUSTER_NAME}"
[ -n "$OUTPUT" ] || OUTPUT="$HOME/.kube/${CLUSTER_NAME}-sso.yaml"

if [ "$TO_STDOUT" -eq 0 ] && [ -e "$OUTPUT" ] && [ "$FORCE" -eq 0 ]; then
  die "$OUTPUT exists (use --force to replace it, or --output to write elsewhere)"
fi

# ---- build ------------------------------------------------------------------
# Assembled with kubectl-independent YAML so the result is identical on every machine; the CA is
# emitted as data (base64), which is safe in a plain scalar and removes any path dependency.
render() {
  cat <<EOF
# Generated by ${PROG} — credential-free by design.
#
# There is no client certificate, token or secret in this file: the exec plugin below fetches a
# short-lived token from the issuer when kubectl runs. Deleting the entry in Keycloak, or removing
# the user's k8s role there, revokes access without touching this file.
apiVersion: v1
kind: Config
clusters:
  - name: "${CLUSTER_NAME}"
    cluster:
      server: "${SERVER}"
EOF
  if [ -n "$CA_DATA" ]; then
    printf '      certificate-authority-data: "%s"\n' "$CA_DATA"
  else
    printf '      insecure-skip-tls-verify: true\n'
  fi
  cat <<EOF
users:
  - name: "${USER_NAME}"
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubelogin
        args:
          - get-token
          - --oidc-issuer-url=${ISSUER}
          - --oidc-client-id=${CLIENT_ID}
EOF
  local s
  for s in "${SCOPES[@]}"; do
    printf '          - --oidc-extra-scope=%s\n' "$s"
  done
  cat <<EOF
        # IfAvailable rather than Always: open a browser when there is one, and fail with a readable
        # message instead of blocking forever on a headless host.
        interactiveMode: IfAvailable
        installHint: |
          kubelogin is required for SSO on this cluster.
            brew install int128/kubelogin/kubelogin
            or: go install github.com/int128/kubelogin@latest
contexts:
  - name: "${CONTEXT_NAME}"
    context:
      cluster: "${CLUSTER_NAME}"
      user: "${USER_NAME}"
current-context: "${CONTEXT_NAME}"
EOF
}

if [ "$TO_STDOUT" -eq 1 ]; then
  FINAL=""
  OUT="$(mktemp)"
  trap 'rm -f "$OUT"' EXIT
  render > "$OUT"
else
  FINAL="$OUTPUT"
  mkdir -p "$(dirname "$FINAL")"
  OUT="$(mktemp "${FINAL}.XXXXXX")"
  trap 'rm -f "$OUT"' EXIT
  render > "$OUT"
fi

# ---- validate before publishing --------------------------------------------
# 1. It parses and resolves. 2. It carries no credential. 3. The exec block is the one we wrote.
kubectl --kubeconfig "$OUT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' >/dev/null 2>&1 \
  || die "generated kubeconfig does not parse; nothing was written"

if grep -Eq '^( *)client-(certificate|key)(-data)?:|^( *)token:' "$OUT"; then
  die "generated kubeconfig contains a credential — this is a bug in $PROG; refusing to publish it"
fi
if [ "$(kubectl --kubeconfig "$OUT" config view --raw -o jsonpath='{.users[0].user.exec.command}')" != "kubelogin" ]; then
  die "generated kubeconfig is not wired to kubelogin; nothing was written"
fi

if [ "$TO_STDOUT" -eq 0 ]; then
  mv "$OUT" "$FINAL"
  chmod 600 "$FINAL"
  trap - EXIT
  OUT="$FINAL"
fi
# Both modes print the result: --stdout because that IS the output, file mode so the user can see
# what they got without opening it.
cat "$OUT"
if [ "$TO_STDOUT" -eq 0 ]; then echo; fi

# ---- what next --------------------------------------------------------------
{
  echo "------------------------------------------------------------------"
  echo "Cluster:  $CLUSTER_NAME ($SERVER)"
  echo "Issuer:   $ISSUER"
  echo "Client:   $CLIENT_ID"
  echo "User:     $USER_NAME  (no credential in the file)"
  if [ "$TO_STDOUT" -eq 0 ]; then echo "Written:  $OUT"; fi
  echo
  if ! command -v kubelogin >/dev/null 2>&1; then
    echo "kubelogin is NOT installed here. Install it before using this kubeconfig:"
    echo "  brew install int128/kubelogin/kubelogin"
    echo "  # or: go install github.com/int128/kubelogin@latest"
    echo
  fi
  echo "Log in and verify (this opens a browser once, then caches the token):"
  if [ "$TO_STDOUT" -eq 0 ]; then
    echo "  kubectl --kubeconfig $OUT auth whoami"
  else
    echo "  kubectl --kubeconfig <file> auth whoami"
  fi
  echo
  echo "Expected: your Keycloak email as the username and, in the groups list,"
  echo "sso:k8s-infra-admin (or -viewer) — that prefixed group is what the RBAC binds."
  echo "------------------------------------------------------------------"
} >&2
