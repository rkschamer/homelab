# Kubernetes Homelab on Proxmox

Was this necessary? Absolutely not. Was it worth it? Absolutely yes. This repo holds the full configuration for a GitOps-driven Kubernetes homelab running on Proxmox VE — infrastructure as code all the way down, with a healthy obsession over network security.

## Stack

### Platform

| Layer | Tool |
|---|---|
| Hypervisor | Proxmox VE |
| Kubernetes OS | [Talos](https://www.talos.dev/) (immutable, no SSH, no nonsense) |
| CNI | [Cilium](https://cilium.io/) with eBPF + Hubble for observability |
| GitOps | [Flux CD](https://fluxcd.io/) |
| Ingress | [Traefik](https://traefik.io/) with ACME/Let's Encrypt |
| Load Balancing | [MetalLB](https://metallb.io/) |
| Storage | [Longhorn](https://longhorn.io/) |
| Secrets | [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) |
| Security | [CrowdSec](https://www.crowdsec.net/) ([docs](docs/crowdsec.md)) |

### Services

#### DMZ — public-facing

| Service | Description |
|---|---|
| [Traefik](https://traefik.io/) | Reverse proxy / ingress controller |
| [Authentik](https://goauthentik.io/) | Identity provider & SSO |
| [CrowdSec](https://www.crowdsec.net/) | Threat detection + Traefik bouncer middleware |

#### Trusted — internal

| Service | Description |
|---|---|
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | Self-hosted Bitwarden-compatible password manager |
| [SiYuan](https://b3log.org/siyuan/en/) | Personal knowledge base / notes |

#### Untrusted — experimental

| Service | Description |
|---|---|
| [Pi-hole](https://pi-hole.net/) + [Unbound](https://nlnetlabs.nl/projects/unbound/) | Network-wide DNS ad blocking with recursive resolver |
| [Snowflake Proxy](https://snowflake.torproject.org/) | Tor pluggable transport proxy |

#### Monitoring

| Service | Description |
|---|---|
| [Prometheus](https://prometheus.io/) | Metrics collection & alerting |
| [Loki](https://grafana.com/oss/loki/) | Log aggregation |
| [Fluent Bit](https://fluentbit.io/) | Log shipping agent |
| [Hubble](https://github.com/cilium/hubble) | Cilium network flow observability |

## Architecture

Internet traffic comes in through a FritzBox router (port-forwarded to the MetalLB pool at `192.168.123.21-29`) and lands on a Proxmox host running two networks:

- **Management (`192.168.123.0/24`)** — control plane, admin access, MetalLB pool
- **Workload (`10.10.20.0/24`)** — all worker nodes

The control plane doubles as a bastion/router between the two networks. Workers route management-bound traffic through it (`10.10.20.2`).

Network isolation between zones (Trusted, DMZ, Untrusted, Monitoring) is enforced **at the pod level** via namespace labels and Cilium Network Policies — not separate physical networks. Pods can run on any worker; the zone follows the namespace.

For the full picture, see [Network Architecture](docs/network-architecture.md) and [Network Policies](docs/network-policies.md).

## Exposed Services

Traefik runs at `192.168.123.21` (MetalLB `traefik` pool). The FritzBox forwards ports 80 and 443 to this IP, making HTTPS services publicly reachable. DNS challenge via Porkbun issues a wildcard cert for `*.kschamer.info`.

¹ Restricted by Traefik IP allowlist to `192.168.123.0/24` (home LAN) even though it routes through the public Traefik entrypoint. CrowdSec threat detection runs as Traefik middleware on all public routes.

### Direct — Pi-hole DNS

| Endpoint | Service | Access |
|----------|---------|--------|
| `10.10.20.100:53` | Pi-hole DNS resolver | Home LAN only |

Exposed via MetalLB `cluster-services` pool on the workload network. Reachable from home LAN via the FritzBox static route (`10.10.20.0/24 → 192.168.123.20`). See [Pi-hole networking](docs/pihole.md) for details on the routing and Cilium policy design.

## Repository Layout

```
.
├── terraform/       # Proxmox VM provisioning
├── talos/           # Talos configs, node network manifests, bootstrap scripts
├── flux/
│   ├── flux-system/       # Flux CD itself
│   ├── infrastructure/    # Platform services (Cilium, MetalLB, Sealed Secrets, Longhorn, ...)
│   ├── dmz/               # DMZ zone services (Traefik, Authentik, CrowdSec)
│   ├── trusted/           # Trusted zone services (Vaultwarden, SiYuan)
│   ├── untrusted/         # Untrusted zone services (Pi-hole, Snowflake Proxy)
│   └── monitoring/        # Monitoring stack (Prometheus, Loki, Fluent Bit)
└── docs/            # The good stuff — detailed docs for each layer
```

## Key Principles

- **GitOps only** — no `kubectl apply` by hand. Everything goes through Flux.
- **Encrypted secrets** — all secrets are SealedSecrets before they touch Git. Plaintext never commits.
- **Immutable infra** — Talos nodes are managed via config, not SSH sessions.

## Encrypted Files

Some files (`terraform.tfvars`, kubeconfig, talosconfig) are encrypted with **git-crypt**. Unlock with the key from Vaultwarden:

```bash
git-crypt unlock /path/to/encryption-key
```

> **Never commit the encryption key.** Sealed Secrets private keys are also not managed by git-crypt — back those up separately (see [Talos Installation](docs/talos-installation.md#backup-the-sealed-secrets-private-key)).

## Further Docs

- [Network Architecture](docs/network-architecture.md)
- [Network Policies and Cilium Debug](docs/network-policies.md)
- [Talos Installation & Cluster Maintenance](docs/talos-installation.md)
- [CrowdSec](docs/crowdsec.md)
- [Pi-hole Networking](docs/pihole.md)
