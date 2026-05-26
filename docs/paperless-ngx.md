# Paperless-ngx

Paperless-ngx is the document management system running in the trusted zone. It ingests, OCR-processes, and archives documents, with AI-assisted metadata tagging via paperless-gpt.

## Architecture

```
Internet → Traefik (DMZ) → paperless-ngx:8000  ← paperless-gpt (polls for work)
                                  │                      │
                             paperless-redis        Ollama (gaming PC)
                                                 lumpy-new.fritz.box:11434
```

**Namespace:** `paperless-ngx` (network-zone: trusted)

**Manifests:** `flux/trusted/paperless-ngx/`

### Pods

| Deployment | Image | Purpose |
|---|---|---|
| `paperless-ngx` | `ghcr.io/paperless-ngx/paperless-ngx:2.20.15` | Webserver + worker + scheduler |
| ↳ sidecar | `gotenberg/gotenberg:8.32` | PDF/Office document conversion (localhost:3000) |
| ↳ sidecar | `apache/tika:3.3.0.0` | Text extraction from Office files (localhost:9998) |
| `paperless-redis` | `redis:8.6.3-alpine` | Task queue (separate pod — survives paperless restarts) |
| `paperless-gpt` | `ghcr.io/icereed/paperless-gpt:v0.25.1` | LLM document classification |

### Storage

| PVC | StorageClass | Size | Mount | Reason |
|---|---|---|---|---|
| `paperless-data` | longhorn | 10Gi | `/usr/src/paperless/data` | SQLite DB + search index; needs fast random I/O |
| `paperless-media` | nfs-synology | 50Gi | `/usr/src/paperless/media` | Document archive on Synology NAS |
| `paperless-consume` | nfs-synology | 5Gi | `/usr/src/paperless/consume` | Inbox — drop files here for ingestion |
| `paperless-redis-data` | longhorn | 1Gi | `/data` | Redis persistence |
| `paperless-gpt-data` | longhorn | 1Gi | `/app/{config,db,prompts}` | paperless-gpt state |

## NFS CSI Driver

NFS volumes are provisioned dynamically by the [NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs) (`csi-driver-nfs:v4.13.2`) from the Synology NAS at `192.168.123.5`.

**StorageClass:** `nfs-synology` (`flux/infrastructure/config/nfs/storageclass.yaml`)

- Server: `192.168.123.5`, share: `/volume1/k8s`
- Creates a subdirectory per PVC: `<namespace>/<pvc-name>` on the NAS automatically
- `reclaimPolicy: Retain` — deleting a PVC does **not** delete NAS data

### Synology NFS Setup

Required DSM configuration (one-time):

1. **DSM → Control Panel → File Services → NFS** — enable NFS service, NFSv4.1 checked
2. **File Station** — create shared folder `k8s` on the main volume (path: `/volume1/k8s`)
3. **Control Panel → Shared Folder → k8s → Edit → NFS Permissions** — create a rule:
   - Hostname/IP: `10.10.20.0/24` (worker nodes)
   - Also add: `192.168.123.20/32` (control plane)
   - Privilege: Read/Write
   - Squash: **No mapping** (`no_root_squash`) — required so the paperless container can `chown` its directories on startup
   - Enable async: yes
   - Allow users to access mounted subfolders: yes

### Host Firewall

Workers need egress to the NAS on port 2049. This is covered in `flux/infrastructure/config/network-policies/host-firewall-policies.yaml` under the `allow-worker-egress` policy (ports 2049 TCP+UDP to 192.168.123.0/24).

## Authentication (OIDC via Authelia)

Paperless uses **Authelia as an OIDC provider** (not just forward-auth), so family members authenticate once via Authelia and are redirected back without a second login prompt.

### Authelia client (`flux/dmz/authelia/authelia-release.yaml`)

- `client_id: paperless`
- `redirect_uri: https://paperless.kschamer.info/accounts/oidc/authelia/login/callback/`
- The hashed client secret lives in the Authelia config; the plaintext version is in the `paperless-secret` SealedSecret as part of `PAPERLESS_SOCIALACCOUNT_PROVIDERS`.

### Paperless-side OIDC config

Set via `PAPERLESS_SOCIALACCOUNT_PROVIDERS` in the sealed secret (JSON blob):

```json
{
  "openid_connect": {
    "APPS": [{
      "provider_id": "authelia",
      "name": "Authelia",
      "client_id": "paperless",
      "secret": "<plaintext client secret>",
      "settings": {
        "server_metadata_url": "https://auth.kschamer.info/.well-known/openid-configuration"
      }
    }]
  }
}
```

Key env vars in `deployment.yaml`:

```yaml
PAPERLESS_APPS: allauth.socialaccount.providers.openid_connect
PAPERLESS_DISABLE_REGULAR_LOGIN: "true"
PAPERLESS_REDIRECT_LOGIN_TO_SSO: "true"
PAPERLESS_SOCIAL_AUTO_SIGNUP: "true"
```

## Secrets (`paperless-sealedsecret.yaml`)

| Key | Description |
|---|---|
| `PAPERLESS_SECRET_KEY` | Django secret key (random string) |
| `PAPERLESS_ADMIN_USER` | Initial superuser username |
| `PAPERLESS_ADMIN_PASSWORD` | Initial superuser password |
| `PAPERLESS_ADMIN_MAIL` | Initial superuser email |
| `PAPERLESS_EMAIL_HOST` | SMTP hostname |
| `PAPERLESS_EMAIL_HOST_USER` | SMTP username |
| `PAPERLESS_EMAIL_HOST_PASSWORD` | SMTP password |
| `PAPERLESS_EMAIL_FROM` | From address for notifications |
| `PAPERLESS_SOCIALACCOUNT_PROVIDERS` | OIDC config JSON (see above) |
| `PAPERLESS_API_TOKEN` | API token for paperless-gpt (see below) |

Re-seal with:
```bash
kubectl create secret generic paperless-secret --dry-run=client -o yaml \
  --from-literal=KEY=value ... | kubeseal --format=yaml > paperless-sealedsecret.yaml
```

## paperless-gpt (AI Document Classification)

paperless-gpt polls for documents tagged `paperless-gpt-auto`, sends them to a local Ollama instance on the gaming PC, and updates the document with AI-suggested title, correspondent, document type, and tags.

**Ollama host:** `lumpy-new.fritz.box:11434` (gaming PC — not always on)

**Queuing behaviour:** if Ollama is unavailable, the tag stays in place and paperless-gpt retries on the next poll cycle. No manual intervention needed.

### Required Ollama models

Pull these on the gaming PC before use:

```bash
ollama pull gemma4:e4b   # text LLM: title, tags, correspondent, document type
ollama pull minicpm-v    # vision LLM: OCR on image-based/scanned documents
```

### First-run setup (PAPERLESS_API_TOKEN)

paperless-gpt needs a Paperless API token, which can only be generated after the first login:

1. Log into `https://paperless.kschamer.info`
2. **Settings → Profile → Generate API Token** — copy the token
3. Re-seal `paperless-secret` with the new `PAPERLESS_API_TOKEN` value
4. Set `replicas: 1` in `paperless-gpt-deployment.yaml` (it ships as `replicas: 0` to avoid crash-loops before the token exists) — or just let Flux pick up the sealed secret update, then manually scale: `kubectl scale deploy/paperless-gpt -n paperless-ngx --replicas=1`

## Ingress

URL: `https://paperless.kschamer.info`

Middlewares: `crowdsec-bouncer` + `authelia-forwardauth` (the forwardauth provides the SSO redirect to Authelia's OIDC endpoint).

## Network Policies

Defined in `network-policies.yaml`:

| Policy | Ingress from | Egress to |
|---|---|---|
| `paperless-ngx` | Traefik (DMZ), paperless-gpt | paperless-redis:6379 |
| `paperless-redis` | paperless-ngx | — |
| `paperless-gpt` | — (no inbound) | paperless-ngx:8000, world:443 (Ollama on gaming PC reaches via trusted zone egress) |

The gaming PC at `lumpy-new.fritz.box` is on the home LAN (192.168.123.0/24). Trusted zone pods can reach it via the cluster-wide egress policy in `flux/infrastructure/config/network-policies/host-firewall-policies.yaml`.

## Useful Commands

```bash
# Check pod status
kubectl get pods -n paperless-ngx

# Watch paperless-gpt processing
kubectl port-forward -n paperless-ngx deploy/paperless-gpt 8080:8080
# then open http://localhost:8080

# Tail paperless logs
kubectl logs -n paperless-ngx deploy/paperless-ngx -c paperless -f

# Tail paperless-gpt logs
kubectl logs -n paperless-ngx deploy/paperless-gpt -f

# Drop a document into the consume inbox
# Copy to the NAS share at /volume1/k8s/paperless-ngx/paperless-consume/
# or use kubectl cp into the consume PVC

# Expand media PVC (online, no restart needed)
kubectl patch pvc paperless-media -n paperless-ngx \
  -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'
```
