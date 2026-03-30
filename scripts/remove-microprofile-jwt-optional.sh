#!/bin/bash
# Script to remove microprofile-jwt from optional scopes for Keycloak clients
# This is a one-time setup script. After running, Crossplane will manage default scopes correctly.

set -e

KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://sso.hnatekmar.xyz}"
REALM="master"

# Clients to fix
CLIENTS=("bao-hnatekmar-xyz" "argocd-bootstrap")

echo "Getting access token..."
TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_ADMIN}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "client_id=admin-cli" \
  -d "grant_type=password" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
  echo "Failed to get access token"
  exit 1
fi

echo "Getting client IDs..."
for CLIENT in "${CLIENTS[@]}"; do
  echo "Processing client: $CLIENT"
  
  # Get client ID
  CLIENT_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT}" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')
  
  if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
    echo "  Client $CLIENT not found"
    continue
  fi
  
  echo "  Client ID: $CLIENT_ID"
  
  # Get current optional scopes
  echo "  Current optional scopes:"
  curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_ID}/default-client-scopes?optional=true" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | "    - \(.name)"'
  
  # Remove microprofile-jwt from optional scopes
  SCOPE_ID=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.[] | select(.name == "microprofile-jwt") | .id')
  
  if [ -z "$SCOPE_ID" ] || [ "$SCOPE_ID" = "null" ]; then
    echo "  microprofile-jwt scope not found, skipping"
    continue
  fi
  
  echo "  Removing microprofile-jwt (scope ID: $SCOPE_ID) from optional scopes..."
  
  # Check if it's currently an optional scope
  IS_OPTIONAL=$(curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_ID}/default-client-scopes?optional=true" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r --arg sid "$SCOPE_ID" '.[] | select(.id == $sid) | .id')
  
  if [ -n "$IS_OPTIONAL" ]; then
    curl -s -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${CLIENT_ID}/default-client-scopes/${SCOPE_ID}" \
      -H "Authorization: Bearer ${TOKEN}"
    echo "  Removed successfully"
  else
    echo "  microprofile-jwt is not an optional scope for this client"
  fi
done

echo "Done! Now Crossplane can add microprofile-jwt as a default scope."
