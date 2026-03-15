## Why

Enable users to authenticate with their GitHub accounts in the Keycloak identity management system, providing a familiar OAuth-based SSO option for users and reducing manual user management overhead. Two separate GitHub identity providers will be configured for two different organizations (algovectra and hnatekmarorg).

## What Changes

- Add two GitHub OAuth identity providers in Keycloak: one for algovectra organization, one for hnatekmarorg organization
- Configure separate GitHub OAuth application callback URLs for each provider
- Map GitHub user attributes from both providers to Keycloak user profiles

## Capabilities

### New Capabilities
- `github-identity-provider`: GitHub OAuth authentication integration allowing users to sign in with GitHub credentials for two separate organizations (algovectra and hnatekmarorg)

### Modified Capabilities

## Impact

- Introduces two new Crossplane `oidc.keycloak.m.crossplane.io/v1alpha1/IdentityProvider` resources (one per organization)
- Requires two GitHub OAuth applications to be configured (one for algovectra, one for hnatekmarorg)
- Enables organization-specific GitHub authentication available in Keycloak at realm://master
