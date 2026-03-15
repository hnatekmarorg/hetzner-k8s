## ADDED Requirements

### Requirement: GitHub Identity Provider Configuration
The system SHALL provide GitHub as an OAuth 2.0 identity provider in Keycloak, configured via Crossplane `oidc.keycloak.m.crossplane.io/v1alpha1/IdentityProvider` resource. Two separate identity providers will be configured for algovectra and hnatekmarorg organizations.

#### Scenario: Identity Provider Resource Created for algovectra
- **WHEN** the Crossplane IdentityProvider resource is applied with provider type `github` and alias for algovectra
- **THEN** Keycloak registers GitHub as an available identity provider for algovectra
- **AND** the resource status indicates successful reconciliation

#### Scenario: Identity Provider Resource Created for hnatekmarorg
- **WHEN** the Crossplane IdentityProvider resource is applied with provider type `github` and alias for hnatekmarorg
- **THEN** Keycloak registers GitHub as an available identity provider for hnatekmarorg
- **AND** the resource status indicates successful reconciliation

#### Scenario: GitHub OAuth Application Properties Configured
- **WHEN** the IdentityProvider resource specifies `clientId` and `clientSecret` in the config section
- **THEN** Keycloak uses these credentials for OAuth flow with GitHub
- **AND** credentials are retrieved from Kubernetes secrets referenced in the resource

### Requirement: Callback URL Configuration
The system SHALL automatically generate and use the correct callback URL for GitHub OAuth authentication.

#### Scenario: Callback URL Accepted by GitHub
- **WHEN** a user initiates GitHub login via Keycloak
- **THEN** the callback matches the format expected by GitHub OAuth application settings
- **AND** GitHub redirects back to Keycloak with authorization code

### Requirement: User Attribute Mapping
The system SHALL map GitHub user attributes to Keycloak user profile properties.

#### Scenario: GitHub Username Mapped
- **WHEN** a user authenticates via GitHub for the first time
- **THEN** the GitHub username is mapped to the Keycloak username attribute
- **AND** a new Keycloak user is created with this username

#### Scenario: GitHub Email Mapped
- **WHEN** a user authenticates via GitHub
- **THEN** the user's primary email from GitHub is mapped to the Keycloak email attribute
- **AND** the email is marked as verified in Keycloak

### Requirement: Authentication Flow
The system SHALL enable users to log in using GitHub credentials through the Keycloak login page.

#### Scenario: User Initiates GitHub Login
- **WHEN** a user clicks the GitHub identity provider button on Keycloak login page
- **THEN** the user is redirected to GitHub authorization page
- **AND** GitHub requests permission to access user account data

#### Scenario: Successful GitHub Authentication
- **WHEN** the user authorizes the GitHub OAuth application
- **THEN** GitHub redirects back to Keycloak with authorization code
- **AND** Keycloak exchanges the code for user access token
- **AND** Keycloak creates a session and authenticates the user

### Requirement: Credential Security
The system SHALL store GitHub OAuth credentials securely using OpenBao and External Secrets Operator.

#### Scenario: Credentials Retrieved from Secret Store
- **WHEN** the Crossplane IdentityProvider resource is created
- **THEN** it references a Kubernetes secret containing GitHub credentials
- **AND** the secret is synced from OpenBao via External Secrets Operator
- **AND** credentials are never stored in plaintext in the repository

### Requirement: Deployment Ordering
The system SHALL deploy the GitHub IdentityProvider resource only after Keycloak and Crossplane provider initialization.

#### Scenario: Sync Wave Applied
- **WHEN** the IdentityProvider resource has the annotation `argocd.argoproj.io/sync-wave: "20"`
- **THEN** ArgoCD waits for Keycloak (wave 0) and Crossplane provider (wave 10) to complete
- **AND** the resource is deployed in the correct order to prevent dependency failures
