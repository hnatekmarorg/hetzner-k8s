#!/usr/bin/env bash
# ============================================================================
# verify-oidc.sh — is this cluster actually ready to authenticate OIDC tokens?
# ============================================================================
#
# WHY THIS EXISTS
# The kubeconfig is the easy half. The half that lives outside Git is kube-apiserver's OIDC
# configuration, and every way of getting it wrong looks the same from kubectl: a bare 401
# "Unauthorized". This script reads the API server's real arguments and reports each one, so a
# missing or misspelt flag is a line of output rather than an afternoon.
#
# It checks, in order:
#   1. kube-apiserver's --oidc-* arguments (issuer, client id, claims, prefixes)
#   2. the issuer's discovery document, from where the API server's network reaches it
#   3. optionally, with --sso-kubeconfig: the identity kubectl actually gets
#
# USAGE
#   ./verify-oidc.sh --kubeconfig ~/.kube/hetzner
#   ./verify-oidc.sh --kubeconfig ~/.kube/hetzner --sso-kubeconfig ~/.kube/hetzner-sso.yaml
#
# OPTIONS
#   --kubeconfig PATH      Admin kubeconfig (needs read on kube-system pods). Default: ~/.kube/config
#   --context NAME         Context to use
#   --sso-kubeconfig PATH  Also run the end-to-end check through the SSO kubeconfig
#   --issuer URL           Expected issuer. Default: https://sso.hnatekmar.xyz/realms/master
#   --client-id ID         Expected client id. Default: kubectl-hnatekmar-xyz
#   -h, --help             This text
#
# EXIT
#   0 all checks passed (or, without --sso-kubeconfig, the static checks did)
#   1 at least one check failed — the reason is printed
# ============================================================================

set -euo pipefail

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
warn() { printf '  warn %s\n' "$*"; }
hdr()  { printf '\n%s\n' "$*"; }
FAILED=0

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
CONTEXT=""
SSO_KUBECONFIG=""
ISSUER="https://sso.hnatekmar.xyz/realms/master"
CLIENT_ID="kubectl-hnatekmar-xyz"
EXPECT_USERNAME_CLAIM="email"
EXPECT_GROUPS_CLAIM="groups"
EXPECT_PREFIX="sso:"

while [ $# -gt 0 ]; do
  case "$1" in
    --kubeconfig)     shift; KUBECONFIG_PATH="${1:?--kubeconfig needs a path}" ;;
    --context)        shift; CONTEXT="${1:?--context needs a name}" ;;
    --sso-kubeconfig) shift; SSO_KUBECONFIG="${1:?--sso-kubeconfig needs a path}" ;;
    --issuer)         shift; ISSUER="${1:?--issuer needs a URL}" ;;
    --client-id)      shift; CLIENT_ID="${1:?--client-id needs a value}" ;;
    -h|--help)        usage 0 ;;
    -*)               die "unknown option: $1 (try --help)" ;;
    *)                die "unexpected argument: $1 (try --help)" ;;
  esac
  shift
done

command -v kubectl >/dev/null 2>&1 || die "kubectl is not on PATH"
[ -f "$KUBECONFIG_PATH" ] || die "kubeconfig not found: $KUBECONFIG_PATH"

KC=(kubectl --kubeconfig "$KUBECONFIG_PATH")
[ -n "$CONTEXT" ] && KC+=(--context "$CONTEXT")

# ---- 1. the API server's arguments -----------------------------------------
hdr "API server OIDC configuration"

# k3s runs the control plane as static pods. The label is the stable selector; the name fallback
# covers distributions that do not label them.
POD="$("${KC[@]}" -n kube-system get pods -l component=kube-apiserver -o name 2>/dev/null | head -1 || true)"
if [ -z "$POD" ]; then
  POD="$("${KC[@]}" -n kube-system get pods -o name 2>/dev/null | grep -E '(^|/)kube-apiserver-' | head -1 || true)"
fi
if [ -z "$POD" ]; then
  bad "no kube-apiserver pod visible in kube-system — cannot read its arguments"
  echo "       Run this from a kubeconfig that can read kube-system pods (the admin one)."
  echo "       On k3s the API server is a static pod named kube-apiserver-<node>."
  ARGS=""
else
  ok "API server pod: ${POD#pod/}"
  ARGS="$("${KC[@]}" -n kube-system get "$POD" -o jsonpath='{range .spec.containers[0].command[*]}{@}{"\n"}{end}')"
  [ -n "$ARGS" ] || warn "pod has no explicit command; it may be managed outside the pod spec"
fi

# `|| true` is load-bearing: with no arguments, grep exits 1 and `set -e` would abort the script
# before it printed a single line of the report it exists to produce.
# Every flag checked here is an --oidc-* one, so the prefix lives in this helper rather than in
# each call site.
arg() { printf '%s\n' "${ARGS:-}" | grep -E -- "^--oidc-$1=" | head -1 | sed 's/^--[a-z-]*=//' || true; }

check_arg() { # name expected description
  local name="$1" expected="$2" desc="$3" got
  got="$(arg "$name")"
  if [ -z "$got" ]; then
    bad "--oidc-$name is not set — $desc"
  elif [ "$got" = "$expected" ]; then
    ok "--oidc-$name=$got"
  else
    bad "--oidc-$name=$got (expected $expected) — $desc"
  fi
}

check_arg issuer-url            "$ISSUER"                  "must equal the Keycloak realm URL"
check_arg client-id             "$CLIENT_ID"               "must equal the kubeconfig's --oidc-client-id"
check_arg username-claim        "$EXPECT_USERNAME_CLAIM"   "the Kubernetes username"
check_arg groups-claim          "$EXPECT_GROUPS_CLAIM"     "the claim RBAC reads"
check_arg username-prefix       "$EXPECT_PREFIX"           "namespaces usernames away from system:"
check_arg groups-prefix         "$EXPECT_PREFIX"           "REQUIRED: RBAC binds sso:k8s-…, not k8s-…"

# An audience check is worth stating: if the API server was given --oidc-required-claim or a client
# id the token's aud does not contain, authentication fails with the same 401.
if printf '%s\n' "${ARGS:-}" | grep -q -- '--oidc-ca-file='; then
  warn "--oidc-ca-file=$(arg ca-file) — the API server trusts this file for the issuer, not the system store"
fi

if [ "$FAILED" -eq 1 ]; then
  cat >&2 <<'YAML'

  Add the missing flags to /etc/rancher/k3s/config.yaml on every server node and restart k3s:

    kube-apiserver-arg:
      - oidc-issuer-url=https://sso.hnatekmar.xyz/realms/master
      - oidc-client-id=kubectl-hnatekmar-xyz
      - oidc-username-claim=email
      - oidc-groups-claim=groups
      - oidc-username-prefix=sso:
      - oidc-groups-prefix=sso:

  Then re-run this script. See docs/kubeconfig-sso.md.
YAML
fi

# ---- 2. the issuer ----------------------------------------------------------
hdr "Issuer discovery"
if command -v curl >/dev/null 2>&1; then
  DISC="$(curl -fsS --max-time 10 "$ISSUER/.well-known/openid-configuration" 2>/dev/null || true)"
  if [ -z "$DISC" ]; then
    bad "cannot fetch $ISSUER/.well-known/openid-configuration"
    echo "       The API SERVER must also reach this URL — it is not enough that your laptop can."
  else
    ok "discovery document reachable"
    # The issuer in the document must match the configured URL byte for byte, trailing slash
    # included. A mismatch is rejected by clients and looks like an invalid token.
    GOT_ISSUER="$(printf '%s' "$DISC" | sed -n 's/.*"issuer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ "$GOT_ISSUER" = "$ISSUER" ]; then
      ok "document issuer matches: $GOT_ISSUER"
    else
      bad "document issuer is '$GOT_ISSUER', expected '$ISSUER'"
    fi
    if printf '%s' "$DISC" | grep -q 'code_challenge_methods_supported'; then
      ok "provider advertises PKCE — kubelogin will use S256 automatically"
    else
      warn "no code_challenge_methods_supported in discovery; kubelogin may skip PKCE and a PUBLIC client will refuse the exchange"
    fi
  fi
else
  warn "curl not found; skipped the issuer check"
fi

# ---- 3. end to end ----------------------------------------------------------
if [ -n "$SSO_KUBECONFIG" ]; then
  hdr "End-to-end: the identity kubectl gets"
  [ -f "$SSO_KUBECONFIG" ] || die "sso kubeconfig not found: $SSO_KUBECONFIG"
  # Its own invocation: KC carries the admin kubeconfig and possibly --context, and a second
  # --kubeconfig would leave kubectl resolving the context against the wrong file.
  if WHO="$(kubectl --kubeconfig "$SSO_KUBECONFIG" auth whoami 2>&1)"; then
    printf '%s\n' "$WHO" | sed 's/^/  /'
    if printf '%s' "$WHO" | grep -q "sso:k8s-"; then
      ok "token carries a prefixed k8s group — RBAC can bind it"
    else
      bad "authenticated but no sso:k8s-* group in the token — the user holds no k8s realm role, or the groups claim is missing"
    fi
  else
    bad "auth whoami failed:"
    printf '%s\n' "$WHO" | sed 's/^/       /'
    echo "       401 = authentication (issuer/client-id/audience). 403 = authenticated, no RBAC binding."
  fi
fi

hdr "Result"
if [ "$FAILED" -eq 0 ]; then
  ok "all checks passed"
  exit 0
fi
bad "at least one check failed (see above)"
exit 1
