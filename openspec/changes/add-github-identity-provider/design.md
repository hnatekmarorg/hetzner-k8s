## Context

The Kubernetes cluster uses Keycloak for identity management, deployed via ArgoCD and configured through Crossplane. The system currently supports various authentication methods, but GitHub OAuth authentication is not yet available. Adding GitHub as an identity provider requires using the Crossplane Keycloak provider resource `oidc.keycloak.m.crossplane.io/v1alpha1/IdentityProvider`.

The Crossplane Keycloak provider is version 2.8.0, and the IdentityProvider resource configuration specifically supports GitHub as one of the built-in identity provider types. The Keycloak deployment is managed through GitOps, with configurations stored in the `argocd/configurations/keycloak/` directory.

## Goals / Non-Goals

**Goals:**
- Create two Crossplane IdentityProvider resources for GitHub OAuth (algovectra and hnatekmarorg organizations)
- Configure GitHub-specific identity provider attributes for each provider (clientId, clientSecret, callback URL)
- Define user attribute mappings from both GitHub organizations to Keycloak profile
- Integrate both resources into the GitOps workflow with proper deployment ordering

**Non-Goals:**
- Creating the GitHub OAuth applications (must be pre-existing, one per organization)
- Multi-realm configuration (single realm focus initially)
- Custom identity provider configuration (using built-in GitHub provider type)
- Group/role mapping automation (user attributes only)
- Organization membership filtering via custom mappers

## Decisions

**1. Realm Configuration Scope**: Create two IdentityProviders in the Keycloak master realm to enable system-wide GitHub authentication for two organizations (algovectra and hnatekmarorg). This allows users from any realm to authenticate with GitHub from either organization, consistent with the current Keycloak multi-warehouse architecture where the master realm serves as the identity hub.

Alternative: Configure per-realm GitHub providers. Rejected because it would require duplicating configuration across multiple realms and managing separate client registrations.

**2. Multiple Provider Strategy**: Create two separate IdentityProvider resources, one for each GitHub organization. Each will have its own OAuth application credentials, clientId, and clientSecret. The providers will be distinguished by their alias (e.g., `github-algovectra` and `github-hnatekmarorg`).

Alternative: Single provider with organization mapping. Rejected because crossplane-contrib/provider-keycloak's GitHub provider type doesn't support organization-level filtering via standard configuration, and we want clear separation of authentication sources.

**3. Crossplane Resource Placement**: Place both IdentityProvider manifests in `crossplane/config/keycloak/identity-providers/` directory alongside existing Keycloak identity configurations. This maintains the established organization pattern where Keycloak resources are grouped by type.

Alternative: Place in `argocd/configurations/keycloak/` directly. Rejected because Crossplane resources (declarative infrastructure) should be separate from ArgoCD application definitions (deployment orchestration).

**4. Attribute Mapping Mapping Strategy**: Use built-in Keycloak GitHub attribute mappings for common fields (username, email) only, configured via the `config` field in each IdentityProvider spec. This keeps the configuration simple and leverages Keycloak's standard GitHub integration.

Alternative: Create custom mappers for additional GitHub attributes. Rejected for initial implementation as it adds complexity and requires understanding of Keycloak's mapper protocol.

**5. Credential Management**: Store GitHub OAuth credentials (clientId, clientSecret) for both organizations in OpenBao and reference them via External Secrets Operator, following the existing security pattern used for all Keycloak and infrastructure credentials. Each organization will have its own secret.

Alternative: Hardcode in Kubernetes secrets. Rejected because it violates the principle of centralized secret management and reduces auditability.

**6. Sync Wave Scheduling**: Set `argocd.argoproj.io/sync-wave: "20"` for both IdentityProvider resources to ensure they deploy after Keycloak (wave 0) and the Keycloak Crossplane provider configuration (wave 10), but before applications that depend on GitHub SSO.

Alternative: Lower priority (wave 0-10). Rejected because the resources depend on Keycloak being ready and the Crossplane provider being configured.

## Risks / Trade-offs

**Risk**: GitHub OAuth application scope misconfiguration may not expose sufficient user attributes for identity mapping.
**Mitigation**: Use standard scopes (`read:user`, `user:email`) for both organizations and validate attribute flows during testing.

**Risk**: GitHub identity providers may conflict with existing user account linking logic.
**Mitigation**: The IdentityProvider resource supports `trustEmail` and `firstBrokerLoginFlowAlias` properties to control automatic account linking and email trust settings. Ensure unique aliases prevent conflicts.

**Risk**: Callback URL misconfiguration causes authentication failures.
**Mitigation**: The Keycloak GitHub integration automatically generates the correct callback URL format; we must ensure both GitHub OAuth applications are configured to accept the Keycloak server's domain.

**Risk**: User account link collisions if same user exists in both GitHub organizations.
**Mitigation**: Keycloak's built-in account linking will create separate accounts unless configured otherwise; this is acceptable as they represent distinct organizational identities.

**Trade-off**: Built-in GitHub provider type offers simplicity but limited customization compared to custom OIDC providers. Additional GitHub-specific attributes require custom mappers, which are out of scope for this implementation.

## Migration Plan

1. Create two OpenBao secrets for GitHub OAuth credentials (algovectra and hnatekmarorg)
2. Configure two External Secrets to sync credentials to crossplane-system namespace (one per organization)
3. Create two Crossplane IdentityProvider resources in `crossplane/config/keycloak/identity-providers/` (algovectra and hnatekmarorg)
4. Commit and let ArgoCD sync the new resources
5. Verify both IdentityProviders are created and reconciled successfully in Keycloak
6. Test GitHub OAuth flow for both organizations by attempting login via Keycloak login page

**Rollback**: Delete both IdentityProvider Crossplane resources; Keycloak will automatically remove the GitHub identity provider configurations.

## Open Questions

- Should GitHub authentication be enabled as a first-screen broker login option, or available as a secondary option only? (Affects `firstBrokerLoginFlowAlias` configuration)
- Should email addresses from GitHub be trusted automatically, or require verification? (Affects `trustEmail` boolean setting)
