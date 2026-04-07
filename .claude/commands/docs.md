Look up documentation for the following: $ARGUMENTS

The argument may name a specific tool followed by a topic (e.g. "talos upgrading a worker node"), or just a topic — in which case infer the relevant tool from context.

Supported tools and their official doc sites:
- **Talos** → docs.siderolabs.com/talos
- **Cilium** → docs.cilium.io
- **CrowdSec** → docs.crowdsec.net
- **Longhorn** → longhorn.io/docs
- **Flux CD** → fluxcd.io/flux
- **Traefik** → doc.traefik.io/traefik

Use WebSearch to find the most relevant page on the appropriate site, then use WebFetch to retrieve it. If the topic spans multiple pages, fetch each relevant one. Base your answer on what the documentation actually says, not on prior training knowledge.

Homelab context for grounding answers:
- Talos on Proxmox, two-network setup (mgmt 192.168.123.0/24, workload 10.10.20.0/24)
- Cilium with eBPF, kube-proxy replacement, VXLAN tunnel mode, host firewall enabled, Hubble observability
- CrowdSec in dmz namespace, integrated with Traefik via bouncer middleware
- Longhorn as distributed block storage, managed via Flux, with backup target configured
- Flux CD for GitOps — all changes go through Flux, never direct kubectl/helm
