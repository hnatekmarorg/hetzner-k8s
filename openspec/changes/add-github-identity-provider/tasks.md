## 1. OpenBao Secret Configuration for algovectra

- [ ] 1.1 Create secret path for algovectra GitHub OAuth credentials in OpenBao
- [ ] 1.2 Store clientId and clientSecret for algovectra in OpenBao using bao CLI or API
- [ ] 1.3 Verify algovectra secret is accessible from OpenBao

## 2. OpenBao Secret Configuration for hnatekmarorg

- [ ] 2.1 Create secret path for hnatekmarorg GitHub OAuth credentials in OpenBao
- [ ] 2.2 Store clientId and clientSecret for hnatekmarorg in OpenBao using bao CLI or API
- [ ] 2.3 Verify hnatekmarorg secret is accessible from OpenBao

## 3. External Secrets Configuration

- [x] 3.1 Create SecretStore reference for OpenBao provider (reuse existing if configured)
- [x] 3.2 Create ExternalSecret for algovectra in crossplane-system namespace
- [x] 3.3 Create ExternalSecret for hnatekmarorg in crossplane-system namespace
- [ ] 3.4 Confirm both secrets are synced to Kubernetes without errors

## 4. Crossplane IdentityProvider Resources

- [x] 4.1 Create `crossplane/config/keycloak/identity-providers/` directory if it doesn't exist
- [x] 4.2 Create algovectra IdentityProvider YAML manifest with provider type `github`, alias `github-algovectra`
- [x] 4.3 Create hnatekmarorg IdentityProvider YAML manifest with provider type `github`, alias `github-hnatekmarorg`
- [x] 4.4 Set annotation `argocd.argoproj.io/sync-wave: "20"` on both IdentityProvider resources
- [x] 4.5 Configure providerConfigRef on both IdentityProviders to reference Keycloak provider
- [x] 4.6 Add GitHub-specific config (clientId, clientSecret from secret reference) for algovectra
- [x] 4.7 Add GitHub-specific config (clientId, clientSecret from secret reference) for hnatekmarorg
- [x] 4.8 Configure keycloakRealmRef on both IdentityProviders to target master realm
- [x] 4.9 Set display name for both identity providers (algovectra and hnatekmarorg)
- [x] 4.10 Configure attribute mappings for username and email on both providers
- [x] 4.11 Dry-run both manifests using `kubectl apply --dry-run=server`

## 5. GitOps Deployment

- [x] 5.1 Commit changes (OpenBao secret creation instructions, ExternalSecrets, IdentityProviders)
- [x] 5.2 Pushed to remote repository
- [ ] 5.3 Monitor ArgoCD application status for errors

## 6. Verification

- [ ] 6.1 Verify both IdentityProvider resources are created and healthy in Keycloak
- [ ] 6.2 Check Crossplane resource reconciliation status for both providers
- [ ] 6.3 Confirm both GitHub providers appear in Keycloak admin console
- [ ] 6.4 Test algovectra GitHub OAuth flow: attempt login via Keycloak login page
- [ ] 6.5 Verify algovectra user account is created with correct username and email mapping
- [ ] 6.6 Test hnatekmarorg GitHub OAuth flow: attempt login via Keycloak login page
- [ ] 6.7 Verify hnatekmarorg user account is created with correct username and email mapping

## 7. Documentation

- [ ] 7.1 Document the OpenBao secret paths and required GitHub OAuth application setup for both organizations
- [ ] 7.2 Update Keycloak SSO integration documentation with both GitHub provider details
- [ ] 7.3 Record any decisions on open questions (broker login flow, email trust)
