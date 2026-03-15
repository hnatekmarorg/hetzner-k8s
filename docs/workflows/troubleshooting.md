# Troubleshooting Guide

This document provides solutions to common issues when working with this Kubernetes infrastructure.

## General Troubleshooting

### Check Resource Status

```bash
kubectl get <resource-type> -A
kubectl describe <resource-type>/<name> -n <namespace>
```

### View Logs

```bash
kubectl logs -n <namespace> <pod-name>
kubectl logs -n <namespace> -l app=<app-label> --tail=100
```

### Check Events

```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

## ArgoCD Issues

### Application Not Syncing

**Symptom**: ArgoCD shows "OutOfSync" after changes

**Check status**:
```bash
kubectl get app <app-name> -n argocd -o yaml
```

**Investigate errors**:
```bash
kubectl describe app <app-name> -n argocd
```

**Common causes**:
- YAML syntax errors: Run `kubectl apply --dry-run=server -f <file>`
- Missing namespace: Add `CreateNamespace=true` to sync options
- Resource conflict: Check for existing resources with same name

### Application Health Degraded

**Symptom**: Application status shows "Degraded" or "Progressing"

**Check pod status**:
```bash
kubectl get pods -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
```

**Check events**:
```bash
kubectl get events -n <namespace>
```

**Common causes**:
- Image pull errors: Check image exists and credentials are correct
- Resource limits exceeded: Check pod requests/limits
- Dependency failure: Check related apps are healthy

### Application Stuck

**Symptom**: Application loops in "Progressing" state

**Force retry**:
```bash
kubectl patch app <app-name> -n argocd --type=merge -p '{"spec":{"syncPolicy":{"retry":{"limit":5}}}}'
```

Check if sync policy is set to manual. If so, sync manually.

## Crossplane Issues

### Provider Not Healthy

**Symptom**: `kubectl get providers.crossplane.io` shows `Unhealthy`

**Check provider pod**:
```bash
kubectl get pods -n crossplane-system -l pkg.crossplane.io/provider
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider --tail=100
```

**Common causes**:
- Package download failed: Check network connectivity
- OOMKilled: Increase resource limits
- Version incompatibility: Check provider version

### Provider Configuration Issues

**Symptom**: Crossplane managed resources stuck in pending state

**Check provider connection**:
```bash
kubectl get providerconfig -n crossplane-system
kubectl describe providerconfig <name> -n crossplane-system
```

**Common causes**:
- Missing credentials secret: Check secret exists and has correct data
- Incorrect service URL: Verify URL is accessible from cluster
- Invalid credentials: Test credentials manually

### Managed Resource Stuck

**Symptom**: Managed resource not provisioning, stuck in pending

**Check resource status**:
```bash
kubectl get <resource-type> -A
kubectl describe <resource-type>/<name> -n <namespace>
```

**Check composition** (if applicable):
```bash
kubectl get composite <name> -n <namespace>
```

**Common causes**:
- Provider not ready: Wait for provider to become healthy
- Missing dependencies: Check required resources exist
- Invalid parameters: Validate specification

## Keycloak Issues

### Group Not Created

**Symptom**: Keycloak group exists in Crossplane but not in Keycloak

**Check resource**:
```bash
kubectl get group <name> -n crossplane-system
kubectl describe group <name> -n crossplane-system
```

**Common causes**:
- Provider not configured: Check `sso-hnatekmar-xyz` provider config
- Invalid credentials: Test Keycloak admin credentials
- Sync wave ordering: Check parent resources are ready

### Role Mapping Not Applied

**Symptom**: Users not receiving roles

**Check mapping**:
```bash
kubectl get roles <mapping-name> -n crossplane-system
kubectl describe roles <mapping-name> -n crossplane-system
```

**Common causes**:
- Group doesn't exist: Verify group resource exists
- Role doesn't exist: Verify role resource exists
- Wrong reference: Check `groupIdRef` and `roleIdsRefs`

### User Can't Authenticate

**Symptom**: Users can't log in to applications using Keycloak

**Keycloak UI**: Check if user exists, is enabled, and has correct group memberships
**Application logs**: Check for authentication errors
**Redirect URIs**: Verify `validRedirectUris` in client config includes application URL

## OpenBao Issues

### OIDC Authentication Fails

**Symptom**: Cannot log in to OpenBao via SSO

**Check OIDC backend**:
```bash
kubectl get authbackend sso -n crossplane-system
kubectl describe authbackend sso -n crossplane-system
```

**Common causes**:
- Invalid client secret: Verify `oidcClientSecretSecretRef`
- Wrong discovery URL: Check `oidcDiscoveryUrl` matches Keycloak
- Role not found: Verify OIDC role exists with matching bound claims

### Policy Not Applied

**Symptom**: Users can't access secrets despite having policy

**Check policy**:
```bash
kubectl get policy <name> -n crossplane-system
kubectl describe policy <name> -n crossplane-system
```

**Test policy**:
```bash
# In OpenBao CLI
bao path capabilities <secret-path> -scope=mytoken
```

**Common causes**:
- Wrong path: Verify policy path matches secret engine mount
- Missing capabilities: Add required capabilities to policy
- Token not refreshed: Users need to log out and back in to get new token

### SSH Certificate Signing Fails

**Symptom**: Cannot sign SSH certificates

**Check SSH engine**:
```bash
kubectl get secretsengine <name> -n crossplane-system
```

**Common causes**:
- SSH engine not enabled: Verify secrets engine is created
- Missing CA cert: Configure SSH CA in OpenBao
- Policy denies access: Check policy grants `create` on `sign` path

## External Secrets Issues

### ExternalSecret Not Syncing

**Symptom**: Kubernetes secret not created or not updating

**Check ExternalSecret status**:
```bash
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>
```

**Check ClusterSecretStore**:
```bash
kubectl get clustersecretstore
kubectl describe clustersecretstore <name>
```

**Common causes**:
- ClusterSecretStore not configured: Verify store exists and is healthy
- Service account permissions: Check SA has role in OpenBao
- Secret path missing: Verify secret exists in OpenBao
- Wrong KV version: Ensure `version` matches OpenBao KV engine

### Template Not Rendering

**Symptom**: Template values are empty or show literal template syntax

**Check secret data**:
```bash
kubectl get secret <name> -n <namespace> -o yaml
```

**Common causes**:
- Wrong remoteRef keys: Verify keys and properties match OpenBao
- Access denied: Check policy allows access to secret path
- KV version mismatch: Ensure `property` is correct for KV v1 (no property) or v2 (requires property)

### Authentication Errors

**Symptom**: `permission denied` or `access denied` errors

**Check service account**:
```bash
kubectl get sa -n external-secrets external-secrets
kubectl describe sa -n external-secrets external-secrets
```

**Check OpenBao role**:
```bash
bao read auth/kubernetes/role/external-secrets
```

**Common causes**:
- Service account doesn't exist: Create SA in external-secrets namespace
- Role missing in OpenBao: Verify role exists in Kubernetes auth backend
- Bound service account mismatch: Check SA name and namespace match role binding

## SSO Integration Issues

### User Gets Wrong Policies

**Symptom**: User can access secrets they shouldn't or can't access secrets they need

**Flow trace**:
1. Check Keycloak group membership via Keycloak UI
2. Check Keycloak realm role assigned to user
3. Check OpenBao OIDC role bound matches group
4. Check OpenBao policy assigned to OIDC role

**Symptoms**:
- Too much access: Check `tokenPolicies` in OIDC role, remove unwanted policies
- Too little access: Check policy grants access to required paths, verify `boundClaims.groups` matches user's group

### Token Expired Too Quickly

**Symptom**: User needs to re-authenticate frequently

**Check OIDC role**:
```bash
kubectl get authbackendrole <name> -n crossplane-system
kubectl describe authbackendrole <name> -n crossplane-system
```

**Solution**: Adjust `tokenTtl` and `tokenMaxTtl` in OIDC role to appropriate values (e.g., 1-4 hours)

## Network Issues

### Can't Reach External Services

**Symptom**: Services can't connect to external APIs (Keycloak, OpenBao, etc.)

**Check from pod**:
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl -v https://bao.hnatekmar.xyz
```

**Common causes**:
- Network policies blocking: Check if network policies exist and allow egress
- DNS resolution: Check DNS is resolving the domain
- Firewall rules: Verify firewall allows outbound traffic to service
- Misconfigured proxy: Check HTTP_PROXY environment variables

### Service Not Reachable from Cluster

**Symptom**: External services can't reach cluster endpoints

**Check ingress**:
```bash
kubectl get ingress -A
kubectl describe ingress <name> -n <namespace>
```

**Common causes**:
- Ingress misconfiguration: Verify ingress rules and hosts
- Load balancer not provisioned: Check cloud provider LB status
- TLS certificate issue: Verify cert is valid and matches hostname

## Performance Issues

### Slow Resource Creation

**Symptom**: Resources taking too long to be created

**Check resource limits**:
```bash
kubectl top nodes
kubectl top pods -n crossplane-system
```

**Common causes**:
- Resource constraints: Increase limits if pods are throttled
- Too many syncs: Reduce ArgoCD sync interval
- Provider overload: Scale up provider pods if needed

## Getting Help

When troubleshooting:

1. **Gather logs**: Capture error logs from all relevant pods
2. **Describe resources**: Run `kubectl describe` on failing resources
3. **Check events**: Review recent events in namespace
4. **Validate configs**: Use `--dry-run=server` to test YAML syntax
5. **Review dependencies**: Ensure dependent resources are ready

For persistent issues, check the individual documentation files for detailed configuration examples:
- [Keycloak](../crossplane/keycloak.md)
- [OpenBao](../crossplane/openbao.md)
- [SSO Integration](../crossplane/sso-integration.md)
- [Provider Configs](../crossplane/provider-configs.md)
- [External Secrets](../crossplane/external-secrets.md)
