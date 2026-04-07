# CrowdSec

CrowdSec provides two layers of protection for inbound HTTP traffic through Traefik:

1. **AppSec (WAF)** — inspects every HTTP request in real-time against rules for known CVEs, SQLi, XSS, path traversal, and other generic attack patterns.
2. **LAPI + CAPI** — the Local API pulls a community-sourced blocklist of known-bad IPs from CrowdSec Central API and feeds decisions to the Traefik bouncer.

## Architecture

```
Internet → Traefik → crowdsec-bouncer middleware
                          │
                          ├─► LAPI (8080)     — is this IP on the blocklist?
                          │                      ↕ syncs with CAPI (crowdsec.net)
                          │
                          └─► AppSec (7422)   — is this request malicious?
                                                 ↕ crowdsecurity/appsec-virtual-patching
                                                   crowdsecurity/appsec-generic-rules
```

Requests are blocked if:
- The source IP matches a LAPI decision (community blocklist or manual ban), **or**
- The AppSec component matches an attack rule

## Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| `crowdsec-lapi` | `crowdsec` | Local API — stores decisions, syncs community blocklist from CAPI |
| `crowdsec-appsec` | `crowdsec` | WAF — real-time HTTP inspection on port 7422 |
| `crowdsec-bouncer` middleware | `traefik` | Traefik plugin — enforces LAPI decisions + AppSec on each request |

### Why the agent is disabled

The agent DaemonSet tails node log files to detect behavioral patterns (brute force, scanning) over time. It requires hostPath volume mounts (`/var/log`) which violate the `baseline` PodSecurity policy.

Granting privileged host access to a security tool that also talks to the internet (CAPI) introduces an unacceptable blast radius — a compromised agent pod could read secrets from other pods' log output across every node.

The incremental value (time-based brute-force detection) does not justify this risk. AppSec + CAPI community blocklist covers the real threat surface.

## Manifests

```
flux/dmz/crowdsec/
├── crowdsec-release.yaml                          # Namespace, HelmRepository, HelmRelease
├── network-policy.yaml                            # Cilium policies (LAPI + AppSec ingress)
├── kustomization.yaml
└── crowdsec-bouncer-sealedsecret.yaml.instructions  # How to create the bouncer API key secret

flux/dmz/traefik/
├── crowdsec-middleware.yaml                       # Traefik Middleware (bouncer plugin config)
└── traefik-release.yaml                           # Plugin registration + CROWDSEC_BOUNCER_API_KEY env
```

## Initial Setup

The Traefik bouncer requires an API key registered with LAPI. This must be done once after the first deploy.

**1. Verify LAPI is running:**
```bash
kubectl rollout status deployment/crowdsec-lapi -n crowdsec
```

**2. Register the Traefik bouncer and capture the key:**
```bash
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli bouncers add traefik-bouncer -o raw
```

**3. Seal the key as a Secret in the `traefik` namespace:**
```bash
kubectl create secret generic crowdsec-bouncer-key \
  --namespace traefik \
  --from-literal=api-key=<KEY_FROM_STEP_2> \
  --dry-run=client -o yaml | kubeseal --format=yaml \
  > flux/dmz/crowdsec/crowdsec-bouncer-sealedsecret.yaml
```

**4. Commit and add the middleware to IngressRoutes:**
```yaml
middlewares:
  - name: crowdsec-bouncer
    namespace: traefik
```

## Useful Commands

### Health check

```bash
# Pod status
kubectl get pods -n crowdsec

# HelmRelease status
kubectl get helmrelease crowdsec -n crowdsec

# Registered bouncers (traefik-bouncer should appear)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli bouncers list

# Installed hub items (AppSec rules, collections)
kubectl exec -n crowdsec deployment/crowdsec-appsec -- cscli hub list
```

### Decisions and alerts

```bash
# Active decisions (banned IPs)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli decisions list

# Recent alerts (triggered rules/scenarios)
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli alerts list

# AppSec metrics — requests processed and blocked per rule
kubectl exec -n crowdsec deployment/crowdsec-lapi -- cscli metrics show appsec
```

### Manual bans

```bash
# Ban an IP for 24 hours
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions add --ip 1.2.3.4 --duration 24h --reason "manual ban"

# Remove a ban
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli decisions delete --ip 1.2.3.4
```

### Testing the WAF

Send a request that matches the `.env` access rule (should return 403 if middleware is active):

```bash
curl -sk https://<your-domain>/.env
```

Or from inside the cluster:
```bash
kubectl run test --rm -it --image=curlimages/curl -- \
  curl -sk https://traefik.traefik.svc.cluster.local/.env \
  -H "Host: yourdomain.kschamer.info"
```

### LAPI logs

```bash
kubectl logs -n crowdsec deployment/crowdsec-lapi --follow
kubectl logs -n crowdsec deployment/crowdsec-appsec --follow
```

## Enroll in CrowdSec Console (optional)

The CrowdSec Console provides a web UI for viewing alerts and decisions across all enrolled engines.

```bash
# Get enrollment token from https://app.crowdsec.net → Security Engines → Enroll
kubectl exec -n crowdsec deployment/crowdsec-lapi -- \
  cscli console enroll <enrollment-token>

# Restart LAPI to apply enrollment
kubectl rollout restart deployment/crowdsec-lapi -n crowdsec
```

Once enrolled, AppSec alerts appear in the Console alongside community blocklist contributions.
