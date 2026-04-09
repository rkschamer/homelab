# Authelia

Authelia is a single sign-on authentication portal that protects internal services via Traefik's ForwardAuth middleware. It replaced Authentik to reduce memory pressure — Authentik consumed ~1 GB idle (server + worker + PostgreSQL); Authelia runs as a single Go binary using ~100 MB.

## Architecture

```
Browser → Traefik → authelia-forwardauth middleware
                         │
                         └─► Authelia (9091)   — is this session authenticated?
                                  │                  if not → redirect to auth.kschamer.info/login
                                  │
                                  └─► SQLite (PVC)      — WebAuthn registrations, brute-force state
```

Protected services redirect unauthenticated requests to `auth.kschamer.info`. After login, Authelia sets a session cookie scoped to `.kschamer.info` and passes identity headers back to Traefik.

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| `authelia` pod | `authelia` | Auth portal — single binary, file-based users, SQLite storage |
| `authelia-forwardauth` middleware | `traefik` | Traefik ForwardAuth pointing to Authelia's `/api/authz/forward-auth` |
| SQLite PVC (1 Gi, Longhorn) | `authelia` | Persists WebAuthn device registrations and brute-force state |

## Limitations

**No user management UI.** Authelia is a pure authentication portal. There is no admin interface — users are managed by editing `users_database.yml` inside the `authelia-secrets` SealedSecret, re-sealing it, and committing. See [User Management](#user-management) below.

## Manifests

```
flux/dmz/authelia/
├── namespace.yaml               # Namespace, network-zone: dmz
├── authelia-release.yaml        # HelmRepository + HelmRelease
├── ingress.yaml                 # IngressRoute at auth.kschamer.info
├── network-policy.yaml          # CiliumNetworkPolicy (port 9091)
├── sealedsecret.yaml            # SealedSecret — authelia-secrets (JWT, session, storage keys + users file)
└── kustomization.yaml

flux/dmz/traefik/
└── authelia-forwardauth-middleware.yaml   # Traefik ForwardAuth middleware
```

## Protected Services

These IngressRoutes use the `authelia-forwardauth` middleware:

| Service | Domain | Ingress file |
|---------|--------|-------------|
| Grafana | `grafana.kschamer.info` | `flux/monitoring/ingress.yaml` |
| Pi-hole | `pihole.kschamer.info` | `flux/untrusted/pi-hole/ingress.yaml` |
| SiYuan | `notes.kschamer.info` | `flux/trusted/siyuan/ingress.yaml` |

To protect additional services, add to their IngressRoute:
```yaml
middlewares:
  - name: authelia-forwardauth
    namespace: traefik
```

## Initial Setup

The `authelia-secrets` SealedSecret must be created before Flux can deploy Authelia.

**1. Hash your password:**
```bash
docker run --rm ghcr.io/authelia/authelia:latest \
  authelia crypto hash generate argon2 --password 'yourpassword'
# Outputs: $argon2id$v=19$...
```

**2. Seal the secret:**
```bash
kubectl create secret generic authelia-secrets -n authelia \
  --from-literal=users_database.yml='users:
  rkschamer:
    displayname: "René Kschamer"
    password: "$argon2id$v=19$..."
    email: "rene.kschamer@gmail.com"
    groups: []' \
  --dry-run=client -o yaml \
  | kubeseal --format=yaml > flux/dmz/authelia/authelia-sealedsecret.yaml
```

> The chart auto-generates JWT, session, and storage encryption keys internally.
> Only `users_database.yml` is needed in this secret.

**3. Commit and let Flux reconcile:**
```bash
git add flux/dmz/authelia/authelia-sealedsecret.yaml
git commit -m "flux(authelia): seal authelia-secrets"
git push
```

## User Management

Authelia has no UI for managing users. To add, remove, or change a user:

**1. Decrypt the current secret (if updating an existing deployment):**
```bash
kubectl get secret authelia-secrets -n authelia -o jsonpath='{.data.users_database\.yml}' \
  | base64 -d
```

**2. Edit `users_database.yml` locally.** Hash any new password first (see step 2 of Initial Setup).

**3. Re-seal and commit** (same `kubectl create secret ... | kubeseal` command as above, overwriting `sealedsecret.yaml`).

Flux will roll out the updated pod automatically.

### Password change

```bash
# Hash new password
docker run --rm ghcr.io/authelia/authelia:latest \
  authelia hash-password -- 'newpassword'

# Then re-seal the secret with the new hash and commit
```

## Useful Commands

### Health check

```bash
kubectl get pods -n authelia
kubectl get helmrelease authelia -n authelia
kubectl logs -n authelia deployment/authelia --follow
```

### Verify ForwardAuth is working

```bash
# Should return 302 redirect to auth.kschamer.info (not 200 or 401)
curl -sI https://grafana.kschamer.info | grep -i location
```

### Check session storage

```bash
# Exec into pod and inspect SQLite DB
kubectl exec -n authelia deployment/authelia -- \
  authelia storage user list --config /config/configuration.yml
```

### Force re-login (invalidate all sessions)

Restart the pod — in-memory sessions are lost on restart:
```bash
kubectl rollout restart deployment/authelia -n authelia
```

## Storage Encryption Key Warning

`STORAGE_ENCRYPTION_KEY` encrypts sensitive fields in the SQLite database. If it is ever changed, the database becomes unreadable. To rotate it safely:

```bash
kubectl exec -n authelia deployment/authelia -- \
  authelia storage encryption change-key \
  --encryption-key.value <new-key> \
  --config /config/configuration.yml
```

Only then update the key in the SealedSecret and re-deploy.
