rene-kschamer_sap: I have a homelab running on a Proxmox VE running with a single node (16CPU, 32GB RAM, 1TB SSD). Currently I have a single VM running as Docker host, which host most of the workload of the home lab. However, over time I got concerned by the security, since at the moment a compromise of a single docker container would have access to all my home network.

Recommend to me a better home lab setup with proper network isoloation.

GitHub Copilot: I'll recommend a comprehensive home lab setup with proper network isolation for your Proxmox VE system. Here's a security-focused architecture:

## Recommended Architecture

### **Network Segmentation (VLANs)**

1. **Management VLAN (VLAN 10)** - 10.0.10.0/24
   - Proxmox host management
   - Access to all other VLANs for administration

2. **Trusted Services VLAN (VLAN 20)** - 10.0.20.0/24
   - Internal services (Home Assistant, file servers, media servers)
   - Full access to home network

3. **DMZ/Public Services VLAN (VLAN 30)** - 10.0.30.0/24
   - Internet-facing services (reverse proxy, VPN endpoint)
   - No direct access to home network

4. **Untrusted/Sandbox VLAN (VLAN 40)** - 10.0.40.0/24
   - Experimental containers, testing
   - Heavily restricted egress only

5. **IoT VLAN (VLAN 50)** - 10.0.50.0/24
   - Smart home devices
   - No inter-device communication

### **VM/Container Layout**

**VM 1: OPNsense Firewall** (2 vCPU, 2GB RAM)
- Acts as router/firewall between VLANs
- Implements firewall rules
- IDS/IPS with Suricata
- VPN server

**VM 2: Trusted Services Docker Host** (4 vCPU, 8GB RAM)
- On VLAN 20
- Home Assistant, Plex, Nextcloud, etc.
- Can access home network resources

**VM 3: DMZ Docker Host** (4 vCPU, 6GB RAM)
- On VLAN 30
- Nginx Proxy Manager, public web services
- Reverse proxy for services in other VLANs

**VM 4: Untrusted/Dev Docker Host** (2 vCPU, 4GB RAM)
- On VLAN 40
- Testing new containers, development
- No access to other VLANs

**VM 5: Kubernetes Cluster (Optional)** (4 vCPU, 8GB RAM)
- For learning/production workloads
- Network policies for pod isolation

**VM 6: Logging/Monitoring** (2 vCPU, 4GB RAM)
- Centralized logging (Graylog/ELK)
- Prometheus + Grafana
- Accessible from management VLAN

### **Security Best Practices**

**Per Docker Host:**
- **AppArmor/SELinux**: Enable mandatory access control
- **User namespaces**: Remap container root to unprivileged host user
- **Read-only root filesystems**: Where possible
- **Network policies**: Use Docker networks per service group
- **Secrets management**: Vault or Docker secrets
- **Regular updates**: Automated with Watchtower (on schedule)

**Firewall Rules (OPNsense):**
```
VLAN 30 (DMZ) → VLAN 20 (Trusted): Allow only specific ports (e.g., 8080 for proxied services)
VLAN 20 (Trusted) → Home Network: Allow all
VLAN 30 (DMZ) → Home Network: Deny all
VLAN 40 (Untrusted) → All internal: Deny all
VLAN 40 (Untrusted) → Internet: Allow (with deep packet inspection)
Management VLAN → All: Allow (from specific IPs only)
```

**Additional Security Layers:**
- **Fail2ban** on each Docker host
- **Crowdsec** for collaborative security
- **Automated backups** using Proxmox Backup Server (PBS) or separate VM
- **Certificate management** with Let's Encrypt via Nginx Proxy Manager
- **2FA** for all web-accessible services

### **Implementation Steps**

1. **Set up VLANs** on your network switch (or use Proxmox virtual networks if no VLAN-capable switch)
2. **Deploy OPNsense VM** as first VM with multiple virtual NICs (one per VLAN + WAN)
3. **Configure firewall rules** with default deny-all, then whitelist needed traffic
4. **Migrate existing containers** gradually to appropriate Docker hosts
5. **Implement monitoring** to track inter-VLAN traffic and detect anomalies
6. **Test isolation** by attempting cross-VLAN access from untrusted VLAN

### **Resource Allocation Summary**
- OPNsense: 2 vCPU, 2GB RAM
- Trusted Docker: 4 vCPU, 8GB RAM
- DMZ Docker: 4 vCPU, 6GB RAM
- Untrusted Docker: 2 vCPU, 4GB RAM
- Monitoring: 2 vCPU, 4GB RAM
- **Remaining**: 2 vCPU, 8GB RAM for additional services

This setup ensures that even if a container in the DMZ is compromised, the attacker cannot pivot to your home network or trusted services. Each layer adds defense in depth.

Would you like me to create detailed configuration files for any specific component (OPNsense rules, Docker compose files with security hardening, etc.)?

rene-kschamer_sap: Could all this also achieved with Kubernetes, whereas I run VMs as nodes?

GitHub Copilot: Absolutely! A Kubernetes-based approach can achieve the same (or better) network isolation while being more scalable and easier to manage. Here's how:

## Kubernetes-Based Architecture

### **Cluster Setup**

**3-5 VMs as K8s Nodes:**
- **Control Plane Node** (4 vCPU, 6GB RAM) - Can also run workloads if using k3s
- **Worker Node 1 - Trusted** (4 vCPU, 10GB RAM) - Labeled for trusted workloads
- **Worker Node 2 - DMZ** (4 vCPU, 8GB RAM) - Labeled for public-facing services
- **Worker Node 3 - Untrusted** (2 vCPU, 4GB RAM) - Labeled for experimental workloads
- **Optional: Storage/Monitoring Node** (2 vCPU, 4GB RAM)

### **Network Isolation Strategies**

**1. Kubernetes Network Policies**
```yaml
# Example: Isolate DMZ namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dmz-isolation
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-controller
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: trusted
    ports:
    - protocol: TCP
      port: 8080
  - to:  # Allow DNS
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  - to:  # Allow internet egress
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 192.168.0.0/16
        - 172.16.0.0/12
```

**2. Namespace-Based Segmentation**
- `management` - Monitoring, logging, admin tools
- `trusted` - Internal services (Nextcloud, Home Assistant)
- `dmz` - Public services (Nginx, external APIs)
- `untrusted` - Development, testing
- `iot` - IoT integrations

**3. Node Affinity/Taints for Physical Isolation**
```yaml
# Deploy DMZ workloads only on dedicated node
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-proxy
  namespace: dmz
spec:
  template:
    spec:
      nodeSelector:
        workload-type: dmz
      tolerations:
      - key: "dmz"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
```

### **Security Advantages Over Plain Docker**

1. **Pod Security Standards**: Enforce restricted/baseline profiles
2. **Service Mesh (Istio/Linkerd)**: mTLS between all services, fine-grained access control
3. **Admission Controllers**: OPA/Gatekeeper to prevent insecure configurations
4. **Secrets Management**: Native secrets + external (Vault, Sealed Secrets)
5. **RBAC**: Granular permissions for service accounts
6. **Runtime Security**: Falco for anomaly detection

### **CNI Options for Enhanced Security**

**Calico** (Recommended)
- Advanced network policies (Layer 7, DNS-based rules)
- Encryption in transit
- eBPF dataplane for performance

**Cilium**
- eBPF-based networking
- Identity-aware security policies
- Transparent encryption

**Multus**
- Multiple network interfaces per pod
- Attach pods to different VLANs directly

### **Example Architecture**

```
┌─────────────────────────────────────────────────┐
│           External Network / Internet            │
└────────────────────┬────────────────────────────┘
                     │
              ┌──────▼──────┐
              │   OPNsense  │  (Optional firewall VM)
              │   or bare   │
              │   K8s LB    │
              └──────┬──────┘
                     │
        ┌────────────▼────────────┐
        │  Ingress Controller     │ (ingress namespace)
        │  (Traefik/Nginx/Envoy)  │
        └────────────┬────────────┘
                     │
        ┌────────────┴────────────┐
        │                         │
   ┌────▼────┐              ┌────▼────┐
   │   DMZ   │              │ Trusted │
   │  Pods   │──────X───────│  Pods   │ (Network Policy blocks)
   └────┬────┘              └────┬────┘
        │                         │
   (Internet                 (Home Network
    egress only)              access allowed)
```

### **Recommended K8s Distribution**

**k3s** (Best for homelab)
- Lightweight (runs on 2 vCPU, 2GB RAM control plane)
- Built-in Traefik ingress
- Easy multi-node setup
- Built-in storage (local-path provisioner)

**Talos Linux** (Most secure)
- Immutable OS
- API-driven (no SSH)
- Built for Kubernetes only
- Minimal attack surface

### **Implementation with Network Policies**

```yaml
# trusted-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: trusted
  labels:
    security-tier: trusted

---
# Default deny all
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: trusted
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress

---
# Allow specific ingress from dmz
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress
  namespace: trusted
spec:
  podSelector:
    matchLabels:
      expose: internal
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-controller
    ports:
    - protocol: TCP
      port: 8080
```

### **Additional Security Layers**

**Service Mesh (Istio)**
```yaml
# Enforce mTLS between all services
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

**OPA Gatekeeper Policy**
```yaml
# Prevent privileged containers
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sPSPPrivilegedContainer
metadata:
  name: psp-privileged-container
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    namespaces:
    - "dmz"
    - "untrusted"
```

### **Pros vs. Traditional VM Approach**

✅ **Dynamic resource allocation** - Better hardware utilization
✅ **Self-healing** - Automatic pod restarts
✅ **Declarative security** - GitOps for network policies
✅ **Built-in service discovery** - No manual networking
✅ **Easier scaling** - Add nodes dynamically
✅ **Better observability** - Prometheus metrics native

❌ **More complex** - Steeper learning curve
❌ **Resource overhead** - K8s components use ~2-4GB RAM
❌ **Kernel sharing** - All pods share host kernel (use gVisor for isolation)

### **Hybrid Approach (Best of Both)**

1. **OPNsense VM** - Perimeter firewall with VLANs
2. **K8s cluster across VLANs** - Worker nodes in different VLANs
3. **Multus CNI** - Pods get IPs from appropriate VLANs
4. **Network Policies** - Additional intra-cluster isolation

This gives you hardware-level VLAN isolation + Kubernetes orchestration benefits.

**Would you like a complete k3s setup guide with network policy examples, or help with a specific component?**

rene-kschamer_sap: I'm running Traefik as reverse proxy. How does it fit into the picture?

GitHub Copilot: Perfect! Traefik integrates beautifully with Kubernetes and can be the central component of your security architecture. Here's how it fits:

## Traefik in Kubernetes Architecture

### **Deployment Strategy**

**Option 1: Traefik as K8s Ingress Controller (Recommended)**
```yaml
# traefik-deployment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    security-tier: ingress

---
# Deploy in DMZ node
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
spec:
  replicas: 2
  template:
    spec:
      nodeSelector:
        workload-type: dmz
      containers:
      - name: traefik
        image: traefik:v3.0
        args:
        - --api.dashboard=true
        - --providers.kubernetescrd
        - --entrypoints.web.address=:80
        - --entrypoints.websecure.address=:443
        - --entrypoints.websecure.http.tls=true
        - --certificatesresolvers.letsencrypt.acme.tlschallenge=true
        - --certificatesresolvers.letsencrypt.acme.email=your@email.com
        - --certificatesresolvers.letsencrypt.acme.storage=/data/acme.json
        ports:
        - name: web
          containerPort: 80
        - name: websecure
          containerPort: 443
```

### **Traffic Flow with Traefik**

```
Internet
   ↓
[OPNsense Firewall] (Optional, port forward 80/443)
   ↓
[Traefik LoadBalancer Service] - DMZ VLAN/Namespace
   ↓
[Traefik Ingress Controller] - Inspects host headers, paths
   ↓
   ├──→ [DMZ Services] (public apps, APIs)
   ├──→ [Trusted Services] (via network policy allow)
   └──→ [Other Namespaces] (via middleware auth)
```

### **Security with Traefik Middlewares**

**1. IP Whitelisting for Admin Services**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: admin-whitelist
  namespace: trusted
spec:
  ipWhiteList:
    sourceRange:
    - 192.168.1.0/24    # Your home network
    - 10.0.20.0/24      # Trusted VLAN
```

**2. Authentication for Internal Services**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: basic-auth
  namespace: trusted
spec:
  basicAuth:
    secret: auth-secret

---
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: trusted
type: Opaque
data:
  users: |
    # htpasswd generated
    dXNlcjE6JGFwcjEkSDY...
```

**3. OAuth/SSO with Authelia or Authentik**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authelia
  namespace: trusted
spec:
  forwardAuth:
    address: http://authelia.trusted.svc.cluster.local:9091/api/verify?rd=https://auth.yourdomain.com
    trustForwardHeader: true
    authResponseHeaders:
    - Remote-User
    - Remote-Groups
```

**4. Rate Limiting (DDoS Protection)**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: rate-limit
  namespace: dmz
spec:
  rateLimit:
    average: 100
    burst: 50
```

### **Network Policy for Traefik**

```yaml
# Allow Traefik to route to all namespaces
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: traefik-egress
  namespace: traefik
spec:
  podSelector:
    matchLabels:
      app: traefik
  policyTypes:
  - Egress
  egress:
  - to:  # Allow to trusted namespace
    - namespaceSelector:
        matchLabels:
          security-tier: trusted
  - to:  # Allow to dmz namespace
    - namespaceSelector:
        matchLabels:
          security-tier: dmz
  - to:  # DNS
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  - to:  # External (for Let's Encrypt)
    - ipBlock:
        cidr: 0.0.0.0/0

---
# Block DMZ services from accessing trusted directly
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: trusted-ingress-only-from-traefik
  namespace: trusted
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          security-tier: ingress
    - podSelector:  # Same namespace communication
        matchLabels: {}
  - from:  # Allow monitoring
    - namespaceSelector:
        matchLabels:
          name: monitoring
```

### **Example Service Routing**

**Public Service (DMZ)**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: public-blog
  namespace: dmz
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(`blog.yourdomain.com`)
    kind: Rule
    services:
    - name: wordpress
      port: 80
    middlewares:
    - name: rate-limit
  tls:
    certResolver: letsencrypt
```

**Internal Service (Trusted) with Auth**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: homeassistant
  namespace: trusted
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(`ha.yourdomain.com`)
    kind: Rule
    services:
    - name: homeassistant
      port: 8123
    middlewares:
    - name: authelia
      namespace: trusted
  tls:
    certResolver: letsencrypt
```

**Admin Service (Management) with IP Whitelist**
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(`traefik.yourdomain.com`)
    kind: Rule
    services:
    - name: api@internal
      kind: TraefikService
    middlewares:
    - name: admin-whitelist
      namespace: trusted
    - name: basic-auth
      namespace: trusted
  tls:
    certResolver: letsencrypt
```

### **Traefik Security Features**

**Enable Security Headers**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: security-headers
  namespace: traefik
spec:
  headers:
    frameDeny: true
    sslRedirect: true
    browserXssFilter: true
    contentTypeNosniff: true
    forceSTSHeader: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 31536000
    customResponseHeaders:
      X-Robots-Tag: "none,noarchive,nosnippet,notranslate,noimageindex"
      server: ""  # Hide server version
```

**Geo-blocking (if needed)**
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: geo-block
  namespace: dmz
spec:
  plugin:
    geoblock:
      allowedCountries:
      - US
      - CA
      - EU
```

### **Complete Architecture**

```
┌─────────────────────────────────────────────┐
│              Internet                        │
└───────────────────┬─────────────────────────┘
                    │
         ┌──────────▼──────────┐
         │   OPNsense (Opt)    │
         │   Port Forward      │
         │   80, 443 → Traefik │
         └──────────┬──────────┘
                    │
         ┌──────────▼──────────┐
         │  Traefik Service    │
         │  (LoadBalancer/     │
         │   NodePort)         │
         └──────────┬──────────┘
                    │
         ┌──────────▼──────────┐
         │  Traefik Pods       │ ← IngressRoutes + Middlewares
         │  (traefik ns)       │
         └─────────┬┬┬─────────┘
                   │││
       ┌───────────┘│└───────────┐
       │            │            │
   ┌───▼───┐   ┌───▼───┐   ┌───▼────┐
   │  DMZ  │   │Trusted│   │ Mgmt   │
   │  NS   │   │  NS   │   │  NS    │
   │       │   │       │   │        │
   │ Blog  │   │HA+Auth│   │Dash+IP │
   │+Rate  │   │       │   │ White  │
   │ Limit │   │       │   │ list   │
   └───────┘   └───────┘   └────────┘
```

### **Migration Path from Docker**

1. **Keep Traefik config format** - Use Traefik CRDs (similar to Docker labels)
2. **Convert Docker Compose** to K8s manifests with IngressRoutes
3. **Preserve middleware chains** - Same auth, rate limiting, etc.
4. **Dynamic config reloading** - Traefik watches K8s API automatically

### **Key Benefits**

✅ **Zero-downtime deployments** - Rolling updates behind Traefik
✅ **Automatic service discovery** - No manual backend configuration
✅ **Native Let's Encrypt** - Per-service automatic cert management
✅ **Middleware reuse** - Define once, apply to multiple routes
✅ **Metrics & tracing** - Prometheus metrics + OpenTelemetry support
✅ **Centralized auth** - One OAuth provider (Authelia) for all services

The beauty is that Traefik becomes your **security enforcement point** - all traffic flows through it, where you apply authentication, authorization, rate limiting, and encryption before it reaches your backend services.

rene-kschamer_sap: How would I setup the nodes VMs in Proxmox? Which K8s distribution to use?

GitHub Copilot: Here's a complete guide for setting up K8s nodes on Proxmox:

## Kubernetes Distribution Choice

### **Recommended: k3s**
Best for homelab due to:
- **Lightweight**: ~512MB RAM per node
- **Single binary**: Easy updates
- **Built-in components**: Traefik, local-path storage, CoreDNS
- **Production-ready**: Used by CNCF projects
- **Easy HA**: Simple multi-master setup

### **Alternative: Talos Linux** (Most Secure)
- Immutable OS, API-only (no SSH)
- Auto-updates
- Minimal attack surface
- Steeper learning curve

### **Not Recommended for Homelab:**
- **kubeadm** - Too manual, more overhead
- **RKE2** - Enterprise-focused, heavier than k3s

## Proxmox VM Setup

### **Base Template Creation**

**1. Download Ubuntu Cloud Image**
```bash
# On Proxmox host
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# Create VM template
qm create 9000 --name ubuntu-k3s-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1

# Resize disk to 32GB
qm resize 9000 scsi0 32G

# Convert to template
qm template 9000
```

**2. Cloud-Init Configuration**
```bash
# Set default user and SSH key
qm set 9000 --ciuser k3sadmin
qm set 9000 --sshkeys ~/.ssh/authorized_keys
qm set 9000 --ipconfig0 ip=dhcp

# Optional: Set nameserver
qm set 9000 --nameserver 1.1.1.1
```

### **Clone VMs for K8s Nodes**

```bash
# Control plane node
qm clone 9000 101 --name k3s-control-01 --full
qm set 101 --cores 4 --memory 6144
qm set 101 --ipconfig0 ip=10.0.20.10/24,gw=10.0.20.1
qm resize 101 scsi0 +8G  # Total 40GB

# Worker nodes
qm clone 9000 201 --name k3s-worker-trusted --full
qm set 201 --cores 4 --memory 10240
qm set 201 --ipconfig0 ip=10.0.20.11/24,gw=10.0.20.1

qm clone 9000 202 --name k3s-worker-dmz --full
qm set 202 --cores 4 --memory 8192
qm set 202 --ipconfig0 ip=10.0.30.10/24,gw=10.0.30.1

qm clone 9000 203 --name k3s-worker-untrusted --full
qm set 203 --cores 2 --memory 4096
qm set 203 --ipconfig0 ip=10.0.40.10/24,gw=10.0.40.1

# Start all VMs
qm start 101 && qm start 201 && qm start 202 && qm start 203
```

### **Network Configuration (VLAN Setup)**

**If you have a VLAN-capable switch:**
```bash
# Add VLAN-aware bridge in Proxmox
# Edit /etc/network/interfaces on Proxmox host

auto vmbr0
iface vmbr0 inet static
    address 10.0.10.2/24
    gateway 10.0.10.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30 40 50

# Tag VMs to specific VLANs
qm set 101 --net0 virtio,bridge=vmbr0,tag=20  # Trusted VLAN
qm set 201 --net0 virtio,bridge=vmbr0,tag=20  # Trusted VLAN
qm set 202 --net0 virtio,bridge=vmbr0,tag=30  # DMZ VLAN
qm set 203 --net0 virtio,bridge=vmbr0,tag=40  # Untrusted VLAN
```

**If no VLAN switch (software-only):**
```bash
# Create multiple bridges
auto vmbr1
iface vmbr1 inet static
    address 10.0.20.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0

auto vmbr2
iface vmbr2 inet static
    address 10.0.30.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0

# Assign VMs to different bridges
qm set 201 --net0 virtio,bridge=vmbr1  # Trusted
qm set 202 --net0 virtio,bridge=vmbr2  # DMZ
```

## K3s Installation

### **1. Control Plane Node Setup**

SSH into VM 101 (`k3s-control-01`):
```bash
ssh k3sadmin@10.0.20.10

# Update system
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-guest-agent

# Install k3s control plane
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --node-name control-01 \
  --tls-san 10.0.20.10 \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

# Get join token
sudo cat /var/lib/rancher/k3s/server/node-token
# Save this token for worker nodes
```

**Why disable Traefik/ServiceLB?**
- You'll deploy Traefik manually with specific config
- Use MetalLB or keep NodePort for more control

### **2. Worker Nodes Setup**

On each worker node:
```bash
# Trusted worker (201)
ssh k3sadmin@10.0.20.11

curl -sfL https://get.k3s.io | K3S_URL=https://10.0.20.10:6443 \
  K3S_TOKEN=<token-from-control-plane> \
  sh -s - agent \
  --node-name worker-trusted \
  --node-label workload-type=trusted

# DMZ worker (202)
ssh k3sadmin@10.0.30.10

curl -sfL https://get.k3s.io | K3S_URL=https://10.0.20.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-dmz \
  --node-label workload-type=dmz \
  --node-taint dmz=true:NoSchedule

# Untrusted worker (203)
ssh k3sadmin@10.0.40.10

curl -sfL https://get.k3s.io | K3S_URL=https://10.0.20.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-untrusted \
  --node-label workload-type=untrusted \
  --node-taint untrusted=true:NoSchedule
```

### **3. Access Cluster from Workstation**

```bash
# On control plane node
sudo cat /etc/rancher/k3s/k3s.yaml

# Copy content to your local machine
mkdir -p ~/.kube
nano ~/.kube/config
# Paste content and change server IP to 10.0.20.10

# Or use scp
scp k3sadmin@10.0.20.10:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/10.0.20.10/g' ~/.kube/config

# Install kubectl
brew install kubectl

# Verify
kubectl get nodes
```

Expected output:
```
NAME                STATUS   ROLES                  AGE   VERSION
control-01          Ready    control-plane,master   5m    v1.28.3+k3s1
worker-trusted      Ready    <none>                 3m    v1.28.3+k3s1
worker-dmz          Ready    <none>                 2m    v1.28.3+k3s1
worker-untrusted    Ready    <none>                 1m    v1.28.3+k3s1
```

## Post-Installation Setup

### **1. Install Calico for Advanced Network Policies**

```bash
# Remove default flannel CNI
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Install Calico
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml

# Verify
kubectl get pods -n calico-system
```

### **2. Install MetalLB for LoadBalancer**

```yaml
# metallb-config.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system

---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.20.100-10.0.20.110  # IP range for LoadBalancers

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
```

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
kubectl apply -f metallb-config.yaml
```

### **3. Deploy Traefik**

```yaml
# traefik-values.yaml
deployment:
  replicas: 2

nodeSelector:
  workload-type: dmz

service:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/address-pool: default-pool

ports:
  web:
    exposedPort: 80
  websecure:
    exposedPort: 443

additionalArguments:
  - "--certificatesresolvers.letsencrypt.acme.email=your@email.com"
  - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
  - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
```

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n traefik --create-namespace -f traefik-values.yaml
```

## Resource Allocation Summary

```
Total: 16 vCPU, 32GB RAM, 1TB SSD

VM 101 - Control:    4 vCPU,  6GB RAM,  40GB disk
VM 201 - Trusted:    4 vCPU, 10GB RAM,  50GB disk
VM 202 - DMZ:        4 vCPU,  8GB RAM,  40GB disk
VM 203 - Untrusted:  2 vCPU,  4GB RAM,  32GB disk
─────────────────────────────────────────────────
Used:               14 vCPU, 28GB RAM, 162GB disk
Reserved (Proxmox):  2 vCPU,  4GB RAM, 100GB+ free
```

## Backup Strategy

```bash
# Create Proxmox backup schedule
pveum useradd backup@pve
pveum passwd backup@pve
pveum acl modify / -user backup@pve -role PVEDatastoreAdmin

# Use Proxmox Backup Server or vzdump
vzdump 101 201 202 203 --compress zstd --mode snapshot --storage local
```

## Monitoring Setup

```bash
# Install kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

This gives you a production-ready homelab cluster with proper isolation, all on your Proxmox host!

rene-kschamer_sap: I'm running a fritzbox router with 192.168.123.0/24 as internal network. The fritzbox does include a firewall. Please make the information you layed out so far based on that

GitHub Copilot: Here's the updated architecture tailored for your FritzBox setup:

## Network Architecture with FritzBox

### **Network Layout**

```
Internet
   ↓
[FritzBox Router/Firewall] - 192.168.123.1
   ↓
[Proxmox Host] - 192.168.123.2 (vmbr0 - Main Bridge)
   ↓
Software VLANs (Linux bridges in Proxmox)
   ├─ vmbr1: 10.10.20.1/24  (Trusted - k3s workers + internal services)
   ├─ vmbr2: 10.10.30.1/24  (DMZ - public-facing services)
   ├─ vmbr3: 10.10.40.1/24  (Untrusted - dev/testing)
   └─ vmbr0: 192.168.123.0/24 (Management - Proxmox + control plane)
```

### **FritzBox Configuration**

**Port Forwarding for External Access:**
```
FritzBox Web UI → Internet → Port Forwarding

HTTP:  External 80   → 192.168.123.100:80  (Traefik LoadBalancer)
HTTPS: External 443  → 192.168.123.100:443 (Traefik LoadBalancer)
```

**Optional: DMZ Host**
- Set 192.168.123.100 (Traefik's IP) as DMZ host if you want all ports forwarded

**Static DHCP Reservations:**
```
192.168.123.2   - proxmox-host
192.168.123.10  - k3s-control-01
192.168.123.100 - Reserved for MetalLB pool
```

## Proxmox Network Configuration

### **Create Software Bridges**

Edit `/etc/network/interfaces` on Proxmox host:

```bash
# Management bridge (connected to FritzBox)
auto vmbr0
iface vmbr0 inet static
    address 192.168.123.2/24
    gateway 192.168.123.1
    bridge-ports enp0s31f6  # Your physical NIC
    bridge-stp off
    bridge-fd 0

# Trusted network bridge (isolated)
auto vmbr1
iface vmbr1 inet static
    address 10.10.20.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.20.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.20.0/24 -o vmbr0 -j MASQUERADE

# DMZ bridge (isolated)
auto vmbr2
iface vmbr2 inet static
    address 10.10.30.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE

# Untrusted bridge (isolated, internet-only)
auto vmbr3
iface vmbr3 inet static
    address 10.10.40.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.40.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.40.0/24 -o vmbr0 -j MASQUERADE
    # Block access to home network
    post-up   iptables -I FORWARD -i vmbr3 -d 192.168.123.0/24 -j DROP
    post-up   iptables -I FORWARD -i vmbr3 -d 10.10.20.0/24 -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d 192.168.123.0/24 -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d 10.10.20.0/24 -j DROP
```

Apply changes:
```bash
systemctl restart networking
# Or reboot Proxmox host
```

## VM Configuration

### **Updated VM Setup**

```bash
# Control plane - on management network (vmbr0)
qm clone 9000 101 --name k3s-control-01 --full
qm set 101 --cores 4 --memory 6144
qm set 101 --net0 virtio,bridge=vmbr0
qm set 101 --ipconfig0 ip=192.168.123.10/24,gw=192.168.123.1
qm set 101 --nameserver 192.168.123.1

# Trusted worker - on trusted bridge (vmbr1)
qm clone 9000 201 --name k3s-worker-trusted --full
qm set 201 --cores 4 --memory 10240
qm set 201 --net0 virtio,bridge=vmbr1
qm set 201 --ipconfig0 ip=10.10.20.11/24,gw=10.10.20.1
qm set 201 --nameserver 192.168.123.1

# DMZ worker - on DMZ bridge (vmbr2)
qm clone 9000 202 --name k3s-worker-dmz --full
qm set 202 --cores 4 --memory 8192
qm set 202 --net0 virtio,bridge=vmbr2
qm set 202 --ipconfig0 ip=10.10.30.10/24,gw=10.10.30.1
qm set 202 --nameserver 192.168.123.1

# Untrusted worker - on untrusted bridge (vmbr3)
qm clone 9000 203 --name k3s-worker-untrusted --full
qm set 203 --cores 2 --memory 4096
qm set 203 --net0 virtio,bridge=vmbr3
qm set 203 --ipconfig0 ip=10.10.40.10/24,gw=10.10.40.1
qm set 203 --nameserver 192.168.123.1

# Start VMs
qm start 101 && qm start 201 && qm start 202 && qm start 203
```

### **Multi-NIC Setup (Recommended)**

For worker nodes to communicate with control plane while staying isolated:

```bash
# Add second NIC to workers for k3s communication
qm set 201 --net1 virtio,bridge=vmbr0
qm set 201 --ipconfig1 ip=192.168.123.21/24

qm set 202 --net1 virtio,bridge=vmbr0
qm set 202 --ipconfig1 ip=192.168.123.22/24

qm set 203 --net1 virtio,bridge=vmbr0
qm set 203 --ipconfig1 ip=192.168.123.23/24
```

**On each worker node, configure routing:**
```bash
# Example on worker-trusted (201)
sudo ip route add default via 10.10.20.1 dev ens18 metric 100
sudo ip route add 192.168.123.0/24 via 192.168.123.1 dev ens19 metric 50
sudo ip route add 10.42.0.0/16 via 192.168.123.10 dev ens19  # k3s pod network

# Make persistent in /etc/netplan/50-cloud-init.yaml
```

## K3s Installation (Updated)

### **Control Plane**

```bash
ssh k3sadmin@192.168.123.10

curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --node-name control-01 \
  --node-ip 192.168.123.10 \
  --advertise-address 192.168.123.10 \
  --tls-san 192.168.123.10 \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

sudo cat /var/lib/rancher/k3s/server/node-token
```

### **Worker Nodes**

```bash
# Trusted worker
ssh k3sadmin@192.168.123.21

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-trusted \
  --node-ip 192.168.123.21 \
  --node-label workload-type=trusted \
  --node-label network-zone=trusted

# DMZ worker
ssh k3sadmin@192.168.123.22

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-dmz \
  --node-ip 192.168.123.22 \
  --node-label workload-type=dmz \
  --node-label network-zone=dmz \
  --node-taint dmz=true:NoSchedule

# Untrusted worker
ssh k3sadmin@192.168.123.23

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-untrusted \
  --node-ip 192.168.123.23 \
  --node-label workload-type=untrusted \
  --node-label network-zone=untrusted \
  --node-taint untrusted=true:NoSchedule
```

## MetalLB Configuration (Updated)

```yaml
# metallb-config.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system

---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-network-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.123.100-192.168.123.110  # IPs on your home network

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-network
  namespace: metallb-system
spec:
  ipAddressPools:
  - home-network-pool
```

Apply:
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
kubectl apply -f metallb-config.yaml
```

## Traefik Deployment (Updated)

```yaml
# traefik-deployment.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: traefik

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik
  namespace: traefik

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: traefik
  namespace: traefik
spec:
  replicas: 2
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik
      nodeSelector:
        workload-type: dmz
      tolerations:
      - key: dmz
        operator: Equal
        value: "true"
        effect: NoSchedule
      containers:
      - name: traefik
        image: traefik:v3.0
        args:
        - --api.dashboard=true
        - --providers.kubernetescrd
        - --entrypoints.web.address=:80
        - --entrypoints.websecure.address=:443
        - --certificatesresolvers.letsencrypt.acme.tlschallenge=true
        - --certificatesresolvers.letsencrypt.acme.email=your@email.com
        - --certificatesresolvers.letsencrypt.acme.storage=/data/acme.json
        ports:
        - name: web
          containerPort: 80
        - name: websecure
          containerPort: 443
        - name: admin
          containerPort: 8080

---
apiVersion: v1
kind: Service
metadata:
  name: traefik
  namespace: traefik
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.123.100  # Request specific IP from MetalLB
  selector:
    app: traefik
  ports:
  - name: web
    port: 80
    targetPort: 80
  - name: websecure
    port: 443
    targetPort: 443
```

Apply:
```bash
kubectl apply -f traefik-deployment.yaml
```

## Network Isolation Summary

```
┌─────────────────────────────────────────┐
│   Internet                               │
└──────────────┬──────────────────────────┘
               │
        ┌──────▼──────┐
        │  FritzBox   │  192.168.123.1
        │  Firewall   │  Port forward 80/443 → .100
        └──────┬──────┘
               │
        ┌──────▼──────────────────────────────┐
        │  Proxmox (vmbr0)  192.168.123.2     │
        └──┬────────┬────────┬────────┬───────┘
           │        │        │        │
     ┌─────▼──┐ ┌──▼────┐ ┌─▼─────┐ ┌▼──────┐
     │Control │ │Trusted│ │  DMZ  │ │Untrst │
     │  .10   │ │ .21   │ │  .22  │ │  .23  │
     │        │ │(vmbr1)│ │(vmbr2)│ │(vmbr3)│
     │ vmbr0  │ │10.10. │ │10.10. │ │10.10. │
     │        │ │20.11  │ │30.10  │ │40.10  │
     └────────┘ └───┬───┘ └───┬───┘ └───┬───┘
                    │         │         │
              Internal   Public     No access
              services   services   to home net
```

**Isolation Rules:**
- ✅ **Trusted** → Home network (192.168.123.0/24): Allowed via NAT
- ✅ **DMZ** → Internet: Allowed via NAT
- ❌ **DMZ** → Home network: Blocked by iptables
- ❌ **DMZ** → Trusted: Blocked by K8s NetworkPolicy
- ✅ **DMZ** ← Traefik ← Trusted: Allowed (reverse proxy only)
- ❌ **Untrusted** → All internal: Blocked
- ✅ **Untrusted** → Internet: Allowed

## Access from Your Workstation

```bash
# Copy kubeconfig from control plane
scp k3sadmin@192.168.123.10:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.123.10/g' ~/.kube/config

# Verify
kubectl get nodes
kubectl get svc -n traefik

# Should see Traefik LoadBalancer with EXTERNAL-IP: 192.168.123.100
```

## DNS Configuration

**Option 1: FritzBox Local DNS**
```
FritzBox → Home Network → Network Settings → DNS Rebind Protection
Add: *.yourdomain.com → 192.168.123.100
```

**Option 2: Split-Brain DNS with Pi-hole**
Deploy Pi-hole on trusted network and configure local DNS entries.

This setup gives you proper network isolation while leveraging FritzBox's firewall for perimeter security and using software bridges in Proxmox for internal segmentation!

rene-kschamer_sap: Okay...Good. After K8s is running. How would I bootstrap the clusters? Consider that I need a proper solution to share secrets.

GitHub Copilot: Here's a comprehensive bootstrap strategy for your k3s cluster with proper secrets management:

## Bootstrap Strategy Overview

```
1. Core Infrastructure (Day 0)
   ↓
2. GitOps + Secrets Management (Day 1)
   ↓
3. Platform Services (Day 2)
   ↓
4. Application Workloads (Day N)
```

## Phase 1: Core Infrastructure Bootstrap

### **1.1 Create Namespace Structure**

```yaml
# namespaces.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: flux-system
  labels:
    toolkit.fluxcd.io/tenant: platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    security-tier: ingress
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: v1
kind: Namespace
metadata:
  name: vault
  labels:
    security-tier: platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: Namespace
metadata:
  name: trusted
  labels:
    security-tier: trusted
---
apiVersion: v1
kind: Namespace
metadata:
  name: dmz
  labels:
    security-tier: dmz
    network-zone: public
---
apiVersion: v1
kind: Namespace
metadata:
  name: untrusted
  labels:
    security-tier: untrusted
```

```bash
kubectl apply -f namespaces.yaml
```

### **1.2 Install Calico (Network Policies)**

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

# Create Calico config
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.42.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  nodeAddressAutodetectionV4:
    interface: eth.*|ens.*
EOF

kubectl get pods -n calico-system --watch
```

### **1.3 Install MetalLB**

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

# Wait for pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Configure IP pool
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-network-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.123.100-192.168.123.110
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-network
  namespace: metallb-system
spec:
  ipAddressPools:
  - home-network-pool
EOF
```

## Phase 2: GitOps + Secrets Management

### **2.1 Install Flux CD**

```bash
# Install Flux CLI
brew install fluxcd/tap/flux

# Check prerequisites
flux check --pre

# Bootstrap Flux with your Git repo
export GITHUB_TOKEN=<your-github-token>
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --private=false

# This creates repo structure:
# homelab-gitops/
# ├── clusters/
# │   └── homelab/
# │       ├── flux-system/
# │       ├── infrastructure/
# │       ├── apps/
# │       └── secrets/
```

### **2.2 Install External Secrets Operator (ESO)**

**Why ESO?** Syncs secrets from external sources (Vault, 1Password, AWS Secrets Manager) into Kubernetes.

```bash
# Add to Flux
flux create source helm external-secrets \
  --url=https://charts.external-secrets.io \
  --namespace=flux-system

flux create helmrelease external-secrets \
  --source=HelmRepository/external-secrets \
  --chart=external-secrets \
  --namespace=external-secrets-system \
  --create-target-namespace=true
```

### **2.3 Install HashiCorp Vault**

```yaml
# vault-values.yaml
server:
  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: local-path

  ha:
    enabled: false

  standalone:
    enabled: true

  service:
    type: ClusterIP

  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
    - host: vault.home.local
      paths:
      - /

  nodeSelector:
    workload-type: trusted

ui:
  enabled: true
```

```bash
# Install Vault via Helm
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-values.yaml

# Initialize Vault
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > vault-keys.json

# IMPORTANT: Save vault-keys.json securely (password manager, encrypted storage)

# Unseal Vault
UNSEAL_KEY_1=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(cat vault-keys.json | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(cat vault-keys.json | jq -r '.unseal_keys_b64[2]')

kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_1
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_2
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_3

# Get root token
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Login to Vault
kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN
```

### **2.4 Configure Vault for Kubernetes**

```bash
# Enable K8s auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configure K8s auth
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Enable KV v2 secrets engine
kubectl exec -n vault vault-0 -- vault secrets enable -path=homelab kv-v2

# Create example secrets
kubectl exec -n vault vault-0 -- vault kv put homelab/database \
  username=dbadmin \
  password=SuperSecret123

kubectl exec -n vault vault-0 -- vault kv put homelab/api-keys \
  openai=sk-xxxx \
  github=ghp_xxxx

# Create policy for apps to read secrets
kubectl exec -n vault vault-0 -- vault policy write homelab-read - <<EOF
path "homelab/data/*" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes role
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/homelab \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=trusted,dmz \
  policies=homelab-read \
  ttl=24h
```

### **2.5 Connect External Secrets to Vault**

```yaml
# vault-secret-store.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: trusted
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: trusted
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "homelab"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "homelab"
          serviceAccountRef:
            name: "external-secrets"
```

```bash
kubectl apply -f vault-secret-store.yaml
```

### **2.6 Example: Sync Secret from Vault**

```yaml
# external-secret-example.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials
  namespace: trusted
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
  data:
  - secretKey: username
    remoteRef:
      key: homelab/database
      property: username
  - secretKey: password
    remoteRef:
      key: homelab/database
      property: password
```

```bash
kubectl apply -f external-secret-example.yaml

# Verify secret was created
kubectl get secret db-credentials -n trusted -o yaml
```

## Phase 3: Platform Services

### **3.1 Install Cert-Manager**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=90s
```

### **3.2 Configure Let's Encrypt Issuers**

```yaml
# letsencrypt-issuers.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
```

```bash
kubectl apply -f letsencrypt-issuers.yaml
```

### **3.3 Deploy Traefik**

```yaml
# traefik-helmrelease.yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 30m
  chart:
    spec:
      chart: traefik
      version: "26.x"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    deployment:
      replicas: 2

    nodeSelector:
      workload-type: dmz

    tolerations:
    - key: dmz
      operator: Equal
      value: "true"
      effect: NoSchedule

    service:
      type: LoadBalancer
      spec:
        loadBalancerIP: 192.168.123.100

    ports:
      web:
        port: 80
        exposedPort: 80
      websecure:
        port: 443
        exposedPort: 443
        tls:
          enabled: true
          certResolver: letsencrypt

    ingressRoute:
      dashboard:
        enabled: true
        matchRule: Host(`traefik.home.local`)
        entryPoints: ["websecure"]

    logs:
      general:
        level: INFO
      access:
        enabled: true

    metrics:
      prometheus:
        enabled: true
```

```bash
kubectl apply -f traefik-helmrelease.yaml
```

### **3.4 Install Monitoring Stack**

```yaml
# kube-prometheus-stack.yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 24h
  url: https://prometheus-community.github.io/helm-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "55.x"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    prometheus:
      prometheusSpec:
        retention: 30d
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: local-path
              resources:
                requests:
                  storage: 50Gi

    grafana:
      adminPassword:
        valueFrom:
          secretKeyRef:
            name: grafana-admin
            key: password

      ingress:
        enabled: true
        ingressClassName: traefik
        hosts:
        - grafana.home.local
```

**Store Grafana password in Vault:**
```bash
# Generate random password
GRAFANA_PASS=$(openssl rand -base64 32)

# Store in Vault
kubectl exec -n vault vault-0 -- vault kv put homelab/grafana \
  password=$GRAFANA_PASS

# Create ExternalSecret to sync it
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
  - secretKey: password
    remoteRef:
      key: homelab/grafana
      property: password
EOF
```

## Phase 4: Default Network Policies

```yaml
# default-network-policies.yaml
# Deny all ingress by default in DMZ
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
# Allow ingress from Traefik to DMZ
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-traefik
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          security-tier: ingress
---
# Allow DNS for all namespaces
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
---
# Block untrusted from accessing internal services
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: untrusted
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
```

```bash
kubectl apply -f default-network-policies.yaml
```

## GitOps Repository Structure

```
homelab-gitops/
├── clusters/
│   └── homelab/
│       ├── flux-system/           # Flux bootstrap
│       ├── infrastructure.yaml    # Infrastructure Kustomization
│       └── apps.yaml              # Apps Kustomization
├── infrastructure/
│   ├── base/
│   │   ├── namespaces/
│   │   ├── metallb/
│   │   ├── traefik/
│   │   ├── cert-manager/
│   │   ├── vault/
│   │   ├── external-secrets/
│   │   └── monitoring/
│   └── homelab/
│       └── kustomization.yaml
├── apps/
│   ├── base/
│   │   ├── homeassistant/
│   │   ├── nextcloud/
│   │   └── plex/
│   └── homelab/
│       └── kustomization.yaml
└── secrets/
    ├── secret-stores.yaml
    └── external-secrets/
```

## Bootstrap Script

```bash
#!/bin/bash
# bootstrap-cluster.sh

set -e

echo "Phase 1: Core Infrastructure"
kubectl apply -f namespaces.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
kubectl apply -f calico-config.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
kubectl apply -f metallb-config.yaml

echo "Phase 2: GitOps + Secrets"
flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab \
  --personal

echo "Phase 3: Wait for Vault"
kubectl wait --namespace vault \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=vault \
  --timeout=300s

echo "Phase 4: Initialize Vault (manual step required)"
echo "Run: kubectl exec -n vault vault-0 -- vault operator init"
echo "Then unseal Vault and configure auth"

echo "Phase 5: Deploy platform services"
kubectl apply -f cert-manager.yaml
kubectl apply -f letsencrypt-issuers.yaml
kubectl apply -f traefik-helmrelease.yaml
kubectl apply -f monitoring.yaml

echo "Phase 6: Apply network policies"
kubectl apply -f default-network-policies.yaml

echo "Bootstrap complete!"
```

## Secret Management Best Practices

1. **Never commit secrets to Git** - Use External Secrets + Vault
2. **Rotate secrets regularly** - Vault TTL + auto-rotation
3. **Use RBAC** - Limit which namespaces can access which secrets
4. **Backup Vault data** - Automated snapshots to external storage
5. **Seal Vault on maintenance** - Re-unseal after Proxmox reboots

## Post-Bootstrap Checklist

```bash
# Verify all core components
kubectl get pods -A

# Check Flux reconciliation
flux get all

# Verify Traefik has LoadBalancer IP
kubectl get svc -n traefik

# Test secret sync
kubectl get externalsecret -A

# Check network policies
kubectl get networkpolicies -A

# View logs
kubectl logs -n flux-system -l app=source-controller
```

This gives you a production-ready, GitOps-managed cluster with secure secrets management!

rene-kschamer_sap: Would cillium an alternative to calico?

GitHub Copilot: Response cleared due to possible match to public code, retrying with modified prompt.Yes, Cilium is an excellent alternative to Calico and often preferred for modern Kubernetes clusters. Here's why:

## Cilium vs Calico Comparison

### **Key Differences**

**Cilium:**
- Uses eBPF (runs in Linux kernel) instead of iptables
- 2-3x better performance and lower latency
- Identity-based security (not just IP addresses)
- Layer 7 network policies (HTTP/gRPC aware)
- Built-in service mesh capabilities
- Native observability with Hubble UI
- Transparent encryption (WireGuard/IPSec)
- Can replace kube-proxy entirely
- Requires Linux kernel 4.9+ (Ubuntu 22.04 ✅)

**Calico:**
- Uses iptables/eBPF (hybrid available)
- More mature, longer track record
- Simpler to troubleshoot (iptables well-known)
- Better documentation ecosystem
- Works on older kernels
- More conservative/proven choice

### **For Your Homelab: Cilium is Better**

Reasons:
- Your Ubuntu VMs support eBPF
- Lower CPU/RAM overhead on limited resources
- Built-in network visualization (great for learning)
- More interesting to experiment with
- Industry moving toward eBPF-based networking

## Install Cilium on k3s

### **1. Install Cilium CLI (on your Mac)**

```bash
brew install cilium-cli
```

### **2. Install Cilium in Cluster**

```bash
# Verify cluster is accessible
kubectl get nodes

# Install Cilium (replaces default CNI)
cilium install \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.123.10 \
  --set k8sServicePort=6443

# Wait for Cilium to be ready
cilium status --wait

# Run connectivity test
cilium connectivity test
```

### **3. If k3s Already Has Flannel**

When installing k3s, disable default CNI:

```bash
# On control plane
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --flannel-backend=none \
  --disable-network-policy \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644

# Then install Cilium
cilium install --version 1.15.0
```

### **4. Install Hubble (Observability UI)**

```bash
# Enable Hubble
cilium hubble enable --ui

# Wait for Hubble to deploy
kubectl rollout status -n kube-system deployment/hubble-ui

# Port-forward to access UI
cilium hubble ui
# Opens http://localhost:12000
```

## Advanced Cilium Features for Your Setup

### **Network Policy with HTTP Awareness**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-specific-api-paths
  namespace: dmz
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
  - fromEndpoints:
    - matchLabels:
        security-tier: ingress
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/public.*"
        - method: "POST"
          path: "/api/v1/webhook"
```

### **Transparent Encryption (WireGuard)**

```bash
# Enable encryption between all pods
cilium upgrade \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

# Verify encryption
cilium status | grep Encryption
```

### **Node-Based Isolation (Physical VLAN Enforcement)**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dmz-node-isolation
  namespace: dmz
spec:
  endpointSelector: {}
  egress:
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: dmz
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
  - toEntities:
    - world  # Allow internet
  - toCIDR:
    - 192.168.123.0/24  # Block home network
      except:
      - 192.168.123.10/32  # Allow k3s API only
```

### **Service Mesh Without Istio**

```yaml
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: rate-limit-api
  namespace: dmz
spec:
  services:
  - name: api-service
    namespace: dmz
  resources:
  - "@type": type.googleapis.com/envoy.config.listener.v3.Listener
    name: envoy-prometheus-metrics-listener
    filterChains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typedConfig:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          httpFilters:
          - name: envoy.filters.http.ratelimit
            typedConfig:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
              domain: api-ratelimit
              rateLimitService:
                grpcService:
                  envoyGrpc:
                    clusterName: rate-limit-cluster
```

## Network Policies for Your Architecture

### **DMZ Namespace Policy**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dmz-isolation
  namespace: dmz
spec:
  endpointSelector: {}

  ingress:
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik

  egress:
  # Allow DNS
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Allow internet but block RFC1918
  - toCIDR:
    - 0.0.0.0/0
    toCIDRSet:
    - cidr: 10.0.0.0/8
      except:
      - 10.42.0.0/16  # Pod network
      - 10.43.0.0/16  # Service network
    - cidr: 172.16.0.0/12
    - cidr: 192.168.0.0/16
```

### **Trusted Namespace Policy**

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: trusted-policies
  namespace: trusted
spec:
  endpointSelector: {}

  ingress:
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik
    - matchLabels:
        io.kubernetes.pod.namespace: trusted

  egress:
  - toEntities:
    - all  # Allow all egress (internal services need flexibility)
```

## Monitoring with Hubble

```bash
# View real-time network flows
cilium hubble observe --namespace dmz

# See what's being blocked
cilium hubble observe --verdict DROPPED

# Check specific pod connections
cilium hubble observe --pod dmz/nginx-xyz

# Export metrics to Prometheus
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/1.15.0/examples/kubernetes/addons/prometheus/monitoring-example.yaml
```

## Troubleshooting Commands

```bash
# Check Cilium status
cilium status

# Verify connectivity
cilium connectivity test

# View policy enforcement
kubectl get cnp -A  # CiliumNetworkPolicy
kubectl describe cnp <name> -n <namespace>

# Debug specific endpoint
cilium endpoint list
cilium endpoint get <endpoint-id>

# Check encryption status
cilium encrypt status
```

## Performance Comparison

**Resource Usage (per node):**
- Calico: ~200MB RAM, 0.1-0.2 vCPU
- Cilium: ~150MB RAM, 0.05-0.1 vCPU (with eBPF)

**Latency:**
- Calico (iptables): ~500-800µs
- Cilium (eBPF): ~100-200µs

For your 16 vCPU / 32GB setup, Cilium will be more efficient.

## Migration Path

If you already installed Calico:

```bash
# Remove Calico
kubectl delete -f calico-manifests.yaml

# Restart all nodes
# (or just restart kubelet)

# Install Cilium
cilium install

# Verify
cilium status
kubectl get pods -A
```

**Recommendation:** Go with Cilium for your homelab. It's cutting-edge, performs better, and the Hubble UI makes it incredibly easy to visualize and debug your network isolation setup.

rene-kschamer_sap: Stick to Calico.

GitHub Copilot: Understood. Calico it is - a solid, proven choice with excellent documentation and easier troubleshooting.

## Updated Bootstrap with Calico

### **Phase 1: Install Calico**

```bash
# Install Tigera operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml

# Configure Calico for k3s
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.42.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
  nodeAddressAutodetectionV4:
    interface: eth.*|ens.*
EOF

# Wait for Calico to be ready
kubectl wait --namespace calico-system \
  --for=condition=ready pod \
  --selector=k8s-app=calico-node \
  --timeout=300s
```

### **Network Policies for Your Setup**

**DMZ Namespace - Strict Isolation**

```yaml
# dmz-network-policies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress

---
# Allow ingress from Traefik only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-traefik
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          security-tier: ingress

---
# Allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53

---
# Allow internet egress but block internal networks
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-internet-only
  namespace: dmz
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.10.20.0/24   # Trusted VLAN
        - 192.168.123.0/24 # Home network (except k3s API)
```

**Trusted Namespace - Allow Home Network**

```yaml
# trusted-network-policies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-traefik
  namespace: trusted
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          security-tier: ingress

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: trusted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53

---
# Allow full egress (trusted services need flexibility)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-egress
  namespace: trusted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
```

**Untrusted Namespace - Internet Only**

```yaml
# untrusted-network-policies.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: untrusted
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress

---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: untrusted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53

---
# Internet only, block all RFC1918
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: internet-only
  namespace: untrusted
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
```

Apply all policies:
```bash
kubectl apply -f dmz-network-policies.yaml
kubectl apply -f trusted-network-policies.yaml
kubectl apply -f untrusted-network-policies.yaml
```

### **Verify Network Policies**

```bash
# List all network policies
kubectl get networkpolicies -A

# Test connectivity between namespaces
kubectl run test-pod --image=nicolaka/netshoot -n dmz --rm -it -- /bin/bash

# Inside pod, test blocked access
curl http://service.trusted.svc.cluster.local  # Should timeout

# Test DNS (should work)
nslookup google.com

# Test internet (should work)
curl https://google.com
```

This gives you a solid Calico-based network isolation setup that's proven and well-documented!

rene-kschamer_sap: Okay, nevermind. Use Cillium with Hubble.

GitHub Copilot: Perfect choice! Here's the updated setup with Cilium + Hubble:

## Phase 1: Install Cilium with Hubble

### **1.1 Install k3s WITHOUT Default CNI**

```bash
# On control plane (192.168.123.10)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --flannel-backend=none \
  --disable-network-policy \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --node-name control-01 \
  --node-ip 192.168.123.10 \
  --advertise-address 192.168.123.10 \
  --tls-san 192.168.123.10 \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

sudo cat /var/lib/rancher/k3s/server/node-token
```

### **1.2 Install Cilium CLI on Mac**

```bash
brew install cilium-cli
```

### **1.3 Deploy Cilium to Cluster**

```bash
# Get kubeconfig
scp k3sadmin@192.168.123.10:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i '' 's/127.0.0.1/192.168.123.10/g' ~/.kube/config

# Install Cilium with Hubble enabled
cilium install \
  --version 1.15.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.123.10 \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true

# Wait for Cilium to be ready
cilium status --wait

# Run connectivity test
cilium connectivity test
```

### **1.4 Join Worker Nodes**

```bash
# Trusted worker (192.168.123.21)
ssh k3sadmin@192.168.123.21

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-trusted \
  --node-ip 192.168.123.21 \
  --node-label workload-type=trusted \
  --node-label network-zone=trusted

# DMZ worker (192.168.123.22)
ssh k3sadmin@192.168.123.22

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-dmz \
  --node-ip 192.168.123.22 \
  --node-label workload-type=dmz \
  --node-label network-zone=dmz \
  --node-taint dmz=true:NoSchedule

# Untrusted worker (192.168.123.23)
ssh k3sadmin@192.168.123.23

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<token> \
  sh -s - agent \
  --node-name worker-untrusted \
  --node-ip 192.168.123.23 \
  --node-label workload-type=untrusted \
  --node-label network-zone=untrusted \
  --node-taint untrusted=true:NoSchedule
```

### **1.5 Verify Cluster**

```bash
kubectl get nodes
kubectl get pods -n kube-system

# Check Cilium status
cilium status
```

## Phase 2: Enable Hubble UI

```bash
# Enable Hubble UI (already enabled in install, but verify)
kubectl get svc -n kube-system hubble-ui

# Port forward to access locally
cilium hubble ui

# This opens: http://localhost:12000
```

**Hubble UI Features:**
- Real-time network flow visualization
- See which pods are communicating
- Identify blocked traffic (policy violations)
- L7 protocol visibility (HTTP, gRPC, DNS)
- Export flows for analysis

## Phase 3: Network Policies with Cilium

### **3.1 DMZ Namespace Policies**

```yaml
# dmz-cilium-policies.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dmz-isolation
  namespace: dmz
spec:
  endpointSelector: {}

  ingress:
  # Allow from Traefik only
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik

  egress:
  # Allow DNS
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Allow internet, block RFC1918
  - toCIDR:
    - 0.0.0.0/0
    toCIDRSet:
    - cidr: 10.0.0.0/8
      except:
      - 10.42.0.0/16  # Pod CIDR
      - 10.43.0.0/16  # Service CIDR
    - cidr: 172.16.0.0/12
    - cidr: 192.168.0.0/16
      except:
      - 192.168.123.10/32  # Allow k8s API
```

### **3.2 Trusted Namespace Policies**

```yaml
# trusted-cilium-policies.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: trusted-policies
  namespace: trusted
spec:
  endpointSelector: {}

  ingress:
  # Allow from Traefik
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik
  # Allow from same namespace
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: trusted

  egress:
  # Allow all (trusted services need flexibility)
  - toEntities:
    - all
```

### **3.3 Untrusted Namespace Policies**

```yaml
# untrusted-cilium-policies.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: untrusted-isolation
  namespace: untrusted
spec:
  endpointSelector: {}

  ingress:
  # Deny all ingress
  - {}

  egress:
  # DNS only
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Internet only, block all private networks
  - toCIDR:
    - 0.0.0.0/0
    toCIDRSet:
    - cidr: 10.0.0.0/8
    - cidr: 172.16.0.0/12
    - cidr: 192.168.0.0/16
```

### **3.4 HTTP-Aware Policy (Advanced)**

```yaml
# http-aware-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-http-policy
  namespace: dmz
spec:
  endpointSelector:
    matchLabels:
      app: api-server

  ingress:
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        # Only allow GET on public endpoints
        - method: "GET"
          path: "/api/v1/public.*"
        # Allow POST on webhook
        - method: "POST"
          path: "/api/v1/webhook"
        # Block admin endpoints
        - method: ".*"
          path: "/admin/.*"
          action: DENY
```

Apply policies:
```bash
kubectl apply -f dmz-cilium-policies.yaml
kubectl apply -f trusted-cilium-policies.yaml
kubectl apply -f untrusted-cilium-policies.yaml
```

## Phase 4: Enable WireGuard Encryption

```bash
# Enable transparent encryption between all pods
cilium upgrade \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

# Verify encryption status
cilium status | grep Encryption
cilium encrypt status

# Should show: "Encryption: Wireguard [NodeEncryption: Disabled]"
```

## Phase 5: Hubble Observability

### **5.1 Access Hubble UI**

```bash
# Port forward (runs in foreground)
cilium hubble ui

# Or expose via Traefik (create IngressRoute)
```

### **5.2 Hubble CLI Commands**

```bash
# Install Hubble CLI
brew install hubble

# Port-forward Hubble Relay
cilium hubble port-forward &

# Watch live flows
hubble observe

# Filter by namespace
hubble observe --namespace dmz

# See denied flows
hubble observe --verdict DROPPED

# See HTTP traffic
hubble observe --protocol http

# Follow specific pod
hubble observe --pod dmz/nginx-xyz

# See DNS queries
hubble observe --protocol dns

# Export to JSON
hubble observe -o json > flows.json
```

### **5.3 Hubble Metrics for Prometheus**

```yaml
# hubble-metrics-servicemonitor.yaml
apiVersion: v1
kind: Service
metadata:
  name: hubble-metrics
  namespace: kube-system
  labels:
    k8s-app: hubble
spec:
  selector:
    k8s-app: cilium
  ports:
  - name: metrics
    port: 9965
    protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hubble
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: hubble
  endpoints:
  - port: metrics
    interval: 30s
```

## Phase 6: Testing Network Policies

```bash
# Create test pods in different namespaces
kubectl run test-dmz --image=nicolaka/netshoot -n dmz --rm -it -- /bin/bash
kubectl run test-trusted --image=nicolaka/netshoot -n trusted --rm -it -- /bin/bash
kubectl run test-untrusted --image=nicolaka/netshoot -n untrusted --rm -it -- /bin/bash

# From DMZ pod - test blocked access to home network
curl http://192.168.123.1  # Should timeout (blocked by policy)

# From DMZ pod - test internet access
curl https://google.com  # Should work

# From trusted pod - test home network
curl http://192.168.123.1  # Should work

# Watch in Hubble UI in real-time!
```

**In Hubble UI you'll see:**
- Green lines: Allowed traffic
- Red lines: Denied traffic
- Protocol details (HTTP GET/POST, DNS queries)
- Latency metrics
- Policy that blocked/allowed the flow

## Phase 7: Install Remaining Platform Services

```bash
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-network-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.123.100-192.168.123.110
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-network
  namespace: metallb-system
EOF

# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Install Flux
flux bootstrap github \
  --owner=<your-github-username> \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab \
  --personal
```

## Bootstrap Script (Complete)

```bash
#!/bin/bash
# bootstrap-cilium-cluster.sh

set -e

echo "==> Phase 1: Install Cilium"
cilium install \
  --version 1.15.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.123.10 \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true

echo "==> Phase 2: Wait for Cilium"
cilium status --wait

echo "==> Phase 3: Enable WireGuard encryption"
cilium upgrade --set encryption.enabled=true --set encryption.type=wireguard

echo "==> Phase 4: Create namespaces"
kubectl apply -f namespaces.yaml

echo "==> Phase 5: Apply network policies"
kubectl apply -f dmz-cilium-policies.yaml
kubectl apply -f trusted-cilium-policies.yaml
kubectl apply -f untrusted-cilium-policies.yaml

echo "==> Phase 6: Install MetalLB"
kubectl apply -f metallb-config.yaml

echo "==> Phase 7: Install cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

echo "==> Phase 8: Bootstrap Flux"
flux bootstrap github --owner=$GITHUB_USER --repository=homelab-gitops --path=clusters/homelab

echo "==> Bootstrap complete!"
echo "==> Access Hubble UI: cilium hubble ui"
echo "==> Check status: cilium status"
```

## Monitoring & Debugging

```bash
# Cilium agent logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=100 -f

# Check endpoint status
cilium endpoint list

# View policy enforcement
kubectl get cnp -A  # CiliumNetworkPolicy
kubectl describe cnp dmz-isolation -n dmz

# Connectivity test
cilium connectivity test

# Performance test
cilium connectivity perf

# Generate network map
hubble observe -o json | hubble-ui-backend --export > network-map.json
```

You now have a cutting-edge, eBPF-powered cluster with full network observability through Hubble!

rene-kschamer_sap: Now combine everything in a single message that concludes this conversation. Make sure that you include, the network setup, the node setup, the kubernetes bootstraping. Please also include to use Flux to manage Helm charts

GitHub Copilot: # Complete Homelab Setup Guide: Secure Kubernetes on Proxmox

## Overview

Transform your Proxmox homelab (16 CPU, 32GB RAM, 1TB SSD) into a secure, production-grade Kubernetes cluster with proper network isolation, GitOps management, and secrets handling.

**Architecture:**
- **Network:** Software VLANs via Proxmox bridges for isolation
- **Kubernetes:** k3s cluster with 4 VMs across security zones
- **CNI:** Cilium with eBPF for performance + Hubble for observability
- **GitOps:** Flux CD for declarative infrastructure
- **Secrets:** HashiCorp Vault + External Secrets Operator
- **Ingress:** Traefik on DMZ nodes
- **Encryption:** WireGuard for pod-to-pod traffic

---

## Part 1: Network Setup in Proxmox

### **1.1 Configure Software Bridges**

SSH into Proxmox host and edit `/etc/network/interfaces`:

```bash
# Management bridge (connected to FritzBox)
auto vmbr0
iface vmbr0 inet static
    address 192.168.123.2/24
    gateway 192.168.123.1
    bridge-ports enp0s31f6  # Your physical NIC
    bridge-stp off
    bridge-fd 0

# Trusted network bridge (isolated)
auto vmbr1
iface vmbr1 inet static
    address 10.10.20.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.20.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.20.0/24 -o vmbr0 -j MASQUERADE

# DMZ bridge (isolated)
auto vmbr2
iface vmbr2 inet static
    address 10.10.30.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.30.0/24 -o vmbr0 -j MASQUERADE

# Untrusted bridge (isolated, internet-only)
auto vmbr3
iface vmbr3 inet static
    address 10.10.40.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s 10.10.40.0/24 -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s 10.10.40.0/24 -o vmbr0 -j MASQUERADE
    # Block access to home network
    post-up   iptables -I FORWARD -i vmbr3 -d 192.168.123.0/24 -j DROP
    post-up   iptables -I FORWARD -i vmbr3 -d 10.10.20.0/24 -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d 192.168.123.0/24 -j DROP
    post-down iptables -D FORWARD -i vmbr3 -d 10.10.20.0/24 -j DROP
```

Apply changes:
```bash
systemctl restart networking
# Or reboot Proxmox host
reboot
```

### **1.2 Configure FritzBox**

**Port Forwarding:**
```
FritzBox Web UI → Internet → Port Forwarding

Protocol  External Port  Internal IP       Internal Port
HTTP      80            192.168.123.100   80
HTTPS     443           192.168.123.100   443
```

**Static DHCP Reservations:**
```
192.168.123.2   - proxmox-host
192.168.123.10  - k3s-control-01
192.168.123.21  - k3s-worker-trusted
192.168.123.22  - k3s-worker-dmz
192.168.123.23  - k3s-worker-untrusted
192.168.123.100 - MetalLB LoadBalancer (Traefik)
```

---

## Part 2: Create VM Template

### **2.1 Download and Prepare Ubuntu Cloud Image**

```bash
# On Proxmox host
cd /tmp
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# Create VM template
qm create 9000 --name ubuntu-k3s-template \
  --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0

# Import disk
qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm

# Configure VM
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1

# Resize disk
qm resize 9000 scsi0 32G

# Configure cloud-init
qm set 9000 --ciuser k3sadmin
qm set 9000 --sshkeys ~/.ssh/authorized_keys
qm set 9000 --nameserver 192.168.123.1
qm set 9000 --ipconfig0 ip=dhcp

# Convert to template
qm template 9000
```

### **2.2 Clone VMs for Kubernetes Nodes**

```bash
# Control plane node (management network)
qm clone 9000 101 --name k3s-control-01 --full
qm set 101 --cores 4 --memory 6144
qm set 101 --net0 virtio,bridge=vmbr0
qm set 101 --ipconfig0 ip=192.168.123.10/24,gw=192.168.123.1
qm resize 101 scsi0 +8G  # 40GB total

# Trusted worker (dual NIC: vmbr1 for workload, vmbr0 for k3s)
qm clone 9000 201 --name k3s-worker-trusted --full
qm set 201 --cores 4 --memory 10240
qm set 201 --net0 virtio,bridge=vmbr1
qm set 201 --net1 virtio,bridge=vmbr0
qm set 201 --ipconfig0 ip=10.10.20.11/24,gw=10.10.20.1
qm set 201 --ipconfig1 ip=192.168.123.21/24
qm resize 201 scsi0 +18G  # 50GB total

# DMZ worker (dual NIC: vmbr2 for workload, vmbr0 for k3s)
qm clone 9000 202 --name k3s-worker-dmz --full
qm set 202 --cores 4 --memory 8192
qm set 202 --net0 virtio,bridge=vmbr2
qm set 202 --net1 virtio,bridge=vmbr0
qm set 202 --ipconfig0 ip=10.10.30.10/24,gw=10.10.30.1
qm set 202 --ipconfig1 ip=192.168.123.22/24
qm resize 202 scsi0 +8G  # 40GB total

# Untrusted worker (dual NIC: vmbr3 for workload, vmbr0 for k3s)
qm clone 9000 203 --name k3s-worker-untrusted --full
qm set 203 --cores 2 --memory 4096
qm set 203 --net0 virtio,bridge=vmbr3
qm set 203 --net1 virtio,bridge=vmbr0
qm set 203 --ipconfig0 ip=10.10.40.10/24,gw=10.10.40.1
qm set 203 --ipconfig1 ip=192.168.123.23/24

# Start all VMs
qm start 101 && qm start 201 && qm start 202 && qm start 203
```

**Resource Allocation Summary:**
```
VM 101 - Control:    4 vCPU,  6GB RAM,  40GB disk
VM 201 - Trusted:    4 vCPU, 10GB RAM,  50GB disk
VM 202 - DMZ:        4 vCPU,  8GB RAM,  40GB disk
VM 203 - Untrusted:  2 vCPU,  4GB RAM,  32GB disk
─────────────────────────────────────────────────
Total:              14 vCPU, 28GB RAM, 162GB disk
Reserved (Proxmox):  2 vCPU,  4GB RAM
```

---

## Part 3: Install k3s Cluster

### **3.1 Install Control Plane (WITHOUT Default CNI)**

```bash
# SSH to control plane
ssh k3sadmin@192.168.123.10

# Install k3s without Flannel (we'll use Cilium)
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --flannel-backend=none \
  --disable-network-policy \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --node-name control-01 \
  --node-ip 192.168.123.10 \
  --advertise-address 192.168.123.10 \
  --tls-san 192.168.123.10 \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16

# Get join token
sudo cat /var/lib/rancher/k3s/server/node-token
# Save this token - you'll need it for workers
```

### **3.2 Join Worker Nodes**

```bash
# Trusted worker
ssh k3sadmin@192.168.123.21

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<your-token-here> \
  sh -s - agent \
  --node-name worker-trusted \
  --node-ip 192.168.123.21 \
  --node-label workload-type=trusted \
  --node-label network-zone=trusted

# DMZ worker
ssh k3sadmin@192.168.123.22

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<your-token-here> \
  sh -s - agent \
  --node-name worker-dmz \
  --node-ip 192.168.123.22 \
  --node-label workload-type=dmz \
  --node-label network-zone=dmz \
  --node-taint dmz=true:NoSchedule

# Untrusted worker
ssh k3sadmin@192.168.123.23

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.123.10:6443 \
  K3S_TOKEN=<your-token-here> \
  sh -s - agent \
  --node-name worker-untrusted \
  --node-ip 192.168.123.23 \
  --node-label workload-type=untrusted \
  --node-label network-zone=untrusted \
  --node-taint untrusted=true:NoSchedule
```

### **3.3 Configure kubectl on Mac**

```bash
# Copy kubeconfig from control plane
scp k3sadmin@192.168.123.10:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Update server address
sed -i '' 's/127.0.0.1/192.168.123.10/g' ~/.kube/config

# Verify connectivity
kubectl get nodes
# Should show NotReady (CNI not installed yet)
```

---

## Part 4: Bootstrap Kubernetes with Cilium

### **4.1 Install Cilium CLI**

```bash
# On your Mac
brew install cilium-cli
```

### **4.2 Deploy Cilium + Hubble**

```bash
# Install Cilium with Hubble enabled
cilium install \
  --version 1.15.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.123.10 \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

# Wait for Cilium to be ready (2-3 minutes)
cilium status --wait

# Run connectivity test
cilium connectivity test

# Verify all nodes are Ready
kubectl get nodes
```

### **4.3 Access Hubble UI**

```bash
# Port forward Hubble UI to localhost
cilium hubble ui

# Opens: http://localhost:12000
# Shows real-time network flows, policy enforcement, protocol visibility
```

### **4.4 Install Hubble CLI**

```bash
brew install hubble

# Port forward Hubble relay
cilium hubble port-forward &

# Watch live network flows
hubble observe

# See denied traffic
hubble observe --verdict DROPPED

# Filter by namespace
hubble observe --namespace dmz

# See HTTP/DNS traffic
hubble observe --protocol http
hubble observe --protocol dns
```

---

## Part 5: Create Namespace Structure

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: flux-system
  labels:
    toolkit.fluxcd.io/tenant: platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    security-tier: ingress
---
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager
---
apiVersion: v1
kind: Namespace
metadata:
  name: vault
  labels:
    security-tier: platform
---
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets-system
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: Namespace
metadata:
  name: trusted
  labels:
    security-tier: trusted
---
apiVersion: v1
kind: Namespace
metadata:
  name: dmz
  labels:
    security-tier: dmz
    network-zone: public
---
apiVersion: v1
kind: Namespace
metadata:
  name: untrusted
  labels:
    security-tier: untrusted
EOF
```

---

## Part 6: Network Policies with Cilium

### **6.1 DMZ Namespace - Strict Isolation**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dmz-isolation
  namespace: dmz
spec:
  endpointSelector: {}

  ingress:
  # Allow from Traefik only
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik

  egress:
  # Allow DNS
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Allow internet, block RFC1918
  - toCIDR:
    - 0.0.0.0/0
    toCIDRSet:
    - cidr: 10.0.0.0/8
      except:
      - 10.42.0.0/16  # Pod CIDR
      - 10.43.0.0/16  # Service CIDR
    - cidr: 172.16.0.0/12
    - cidr: 192.168.0.0/16
      except:
      - 192.168.123.10/32  # Allow k8s API
EOF
```

### **6.2 Trusted Namespace - Full Access**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: trusted-policies
  namespace: trusted
spec:
  endpointSelector: {}

  ingress:
  # Allow from Traefik
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: traefik
  # Allow from same namespace
  - fromEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: trusted

  egress:
  # Allow all (trusted services need flexibility)
  - toEntities:
    - all
EOF
```

### **6.3 Untrusted Namespace - Internet Only**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: untrusted-isolation
  namespace: untrusted
spec:
  endpointSelector: {}

  ingress:
  # Deny all ingress
  - {}

  egress:
  # DNS only
  - toEndpoints:
    - matchLabels:
        io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP

  # Internet only, block all private networks
  - toCIDR:
    - 0.0.0.0/0
    toCIDRSet:
    - cidr: 10.0.0.0/8
    - cidr: 172.16.0.0/12
    - cidr: 192.168.0.0/16
EOF
```

### **6.4 Verify Policies**

```bash
# List all Cilium policies
kubectl get cnp -A

# Test isolation (run in DMZ namespace)
kubectl run test-dmz --image=nicolaka/netshoot -n dmz --rm -it -- bash

# Inside pod:
curl http://192.168.123.1  # Should timeout (blocked)
curl https://google.com     # Should work
nslookup google.com         # Should work

# Watch in Hubble UI to see flows in real-time!
```

---

## Part 7: Install MetalLB

```bash
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

# Wait for MetalLB pods
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Configure IP pool
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: home-network-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.123.100-192.168.123.110
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: home-network
  namespace: metallb-system
spec:
  ipAddressPools:
  - home-network-pool
EOF
```

---

## Part 8: Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=90s

# Configure Let's Encrypt issuers
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: traefik
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
EOF
```

---

## Part 9: Bootstrap Flux CD

### **9.1 Install Flux CLI**

```bash
brew install fluxcd/tap/flux
```

### **9.2 Create GitHub Token**

```bash
# Go to: https://github.com/settings/tokens
# Create token with: repo, admin:repo_hook permissions
export GITHUB_TOKEN=<your-token>
export GITHUB_USER=<your-username>
```

### **9.3 Bootstrap Flux**

```bash
# Bootstrap Flux (creates repo if doesn't exist)
flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab \
  --personal \
  --private=false

# Verify Flux installation
flux check

# Watch reconciliation
flux get all
```

### **9.4 GitOps Repository Structure**

Flux creates this structure in your repo:

```
homelab-gitops/
├── clusters/
│   └── homelab/
│       ├── flux-system/              # Flux components
│       │   ├── gotk-components.yaml
│       │   ├── gotk-sync.yaml
│       │   └── kustomization.yaml
│       ├── infrastructure.yaml       # Infrastructure Kustomization
│       └── apps.yaml                 # Apps Kustomization
├── infrastructure/
│   ├── sources/                      # Helm repositories
│   │   ├── traefik.yaml
│   │   ├── prometheus-community.yaml
│   │   ├── external-secrets.yaml
│   │   └── hashicorp.yaml
│   ├── base/
│   │   ├── traefik/
│   │   │   ├── namespace.yaml
│   │   │   ├── helmrelease.yaml
│   │   │   └── values.yaml
│   │   ├── vault/
│   │   │   ├── namespace.yaml
│   │   │   └── helmrelease.yaml
│   │   ├── external-secrets/
│   │   │   └── helmrelease.yaml
│   │   └── monitoring/
│   │       └── helmrelease.yaml
│   └── homelab/
│       └── kustomization.yaml
├── apps/
│   ├── base/
│   │   ├── homeassistant/
│   │   ├── nextcloud/
│   │   └── plex/
│   └── homelab/
│       └── kustomization.yaml
└── secrets/
    ├── secret-stores.yaml
    └── external-secrets/
```

---

## Part 10: Configure Flux to Manage Infrastructure

### **10.1 Create Infrastructure Kustomization**

```bash
# In your homelab-gitops repo
mkdir -p infrastructure/sources infrastructure/base/traefik infrastructure/base/vault infrastructure/base/external-secrets infrastructure/base/monitoring

# Create infrastructure.yaml in clusters/homelab/
cat > clusters/homelab/infrastructure.yaml <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./infrastructure/homelab
  prune: true
  wait: true
  timeout: 5m
EOF
```

### **10.2 Add Helm Repository Sources**

```bash
# infrastructure/sources/traefik.yaml
cat > infrastructure/sources/traefik.yaml <<EOF
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: traefik
  namespace: flux-system
spec:
  interval: 24h
  url: https://traefik.github.io/charts
EOF

# infrastructure/sources/hashicorp.yaml
cat > infrastructure/sources/hashicorp.yaml <<EOF
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: hashicorp
  namespace: flux-system
spec:
  interval: 24h
  url: https://helm.releases.hashicorp.com
EOF

# infrastructure/sources/external-secrets.yaml
cat > infrastructure/sources/external-secrets.yaml <<EOF
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.external-secrets.io
EOF

# infrastructure/sources/prometheus-community.yaml
cat > infrastructure/sources/prometheus-community.yaml <<EOF
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: prometheus-community
  namespace: flux-system
spec:
  interval: 24h
  url: https://prometheus-community.github.io/helm-charts
EOF
```

### **10.3 Deploy Traefik via Flux**

```bash
# infrastructure/base/traefik/helmrelease.yaml
cat > infrastructure/base/traefik/helmrelease.yaml <<EOF
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  interval: 30m
  chart:
    spec:
      chart: traefik
      version: "26.x"
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    deployment:
      replicas: 2

    nodeSelector:
      workload-type: dmz

    tolerations:
    - key: dmz
      operator: Equal
      value: "true"
      effect: NoSchedule

    service:
      type: LoadBalancer
      spec:
        loadBalancerIP: 192.168.123.100

    ports:
      web:
        port: 80
        exposedPort: 80
        redirectTo:
          port: websecure
      websecure:
        port: 443
        exposedPort: 443
        tls:
          enabled: true

    ingressRoute:
      dashboard:
        enabled: true
        matchRule: Host(\`traefik.home.local\`)
        entryPoints: ["websecure"]

    logs:
      general:
        level: INFO
      access:
        enabled: true

    metrics:
      prometheus:
        enabled: true
        addEntryPointsLabels: true
        addServicesLabels: true

    globalArguments:
    - "--certificatesresolvers.letsencrypt.acme.email=your@email.com"
    - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
    - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
EOF
```

### **10.4 Deploy Vault via Flux**

```bash
# infrastructure/base/vault/helmrelease.yaml
cat > infrastructure/base/vault/helmrelease.yaml <<EOF
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: vault
  namespace: vault
spec:
  interval: 30m
  chart:
    spec:
      chart: vault
      version: "0.27.x"
      sourceRef:
        kind: HelmRepository
        name: hashicorp
        namespace: flux-system
  values:
    server:
      dataStorage:
        enabled: true
        size: 10Gi
        storageClass: local-path

      ha:
        enabled: false

      standalone:
        enabled: true

      service:
        type: ClusterIP

      nodeSelector:
        workload-type: trusted

    ui:
      enabled: true
EOF
```

### **10.5 Deploy External Secrets Operator via Flux**

```bash
# infrastructure/base/external-secrets/helmrelease.yaml
cat > infrastructure/base/external-secrets/helmrelease.yaml <<EOF
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: external-secrets
  namespace: external-secrets-system
spec:
  interval: 30m
  chart:
    spec:
      chart: external-secrets
      version: "0.9.x"
      sourceRef:
        kind: HelmRepository
        name: external-secrets
        namespace: flux-system
  values:
    installCRDs: true
EOF
```

### **10.6 Deploy Monitoring Stack via Flux**

```bash
# infrastructure/base/monitoring/helmrelease.yaml
cat > infrastructure/base/monitoring/helmrelease.yaml <<EOF
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: "55.x"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    prometheus:
      prometheusSpec:
        retention: 30d
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: local-path
              resources:
                requests:
                  storage: 50Gi

    grafana:
      adminPassword: changeme  # Change via Vault later

      ingress:
        enabled: true
        ingressClassName: traefik
        hosts:
        - grafana.home.local
        annotations:
          cert-manager.io/cluster-issuer: letsencrypt-staging

    alertmanager:
      enabled: true
EOF
```

### **10.7 Create Infrastructure Kustomization**

```bash
# infrastructure/homelab/kustomization.yaml
cat > infrastructure/homelab/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  # Helm repositories
  - ../sources/traefik.yaml
  - ../sources/hashicorp.yaml
  - ../sources/external-secrets.yaml
  - ../sources/prometheus-community.yaml

  # Infrastructure components
  - ../base/traefik/helmrelease.yaml
  - ../base/vault/helmrelease.yaml
  - ../base/external-secrets/helmrelease.yaml
  - ../base/monitoring/helmrelease.yaml
EOF
```

### **10.8 Commit and Push**

```bash
git add .
git commit -m "Add infrastructure with Flux"
git push

# Watch Flux reconcile
flux reconcile source git flux-system
flux get helmreleases -A --watch
```

---

## Part 11: Configure Vault for Secrets Management

### **11.1 Initialize Vault**

```bash
# Wait for Vault pod to be ready
kubectl wait --namespace vault \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=vault \
  --timeout=300s

# Initialize Vault
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > vault-keys.json

# CRITICAL: Save vault-keys.json securely!
# Store in password manager or encrypted storage

# Unseal Vault
UNSEAL_KEY_1=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(cat vault-keys.json | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(cat vault-keys.json | jq -r '.unseal_keys_b64[2]')

kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_1
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_2
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY_3

# Verify Vault is unsealed
kubectl exec -n vault vault-0 -- vault status
```

### **11.2 Configure Vault**

```bash
# Get root token
ROOT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Login to Vault
kubectl exec -n vault vault-0 -- vault login $ROOT_TOKEN

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Enable KV v2 secrets engine
kubectl exec -n vault vault-0 -- vault secrets enable -path=homelab kv-v2

# Create example secrets
kubectl exec -n vault vault-0 -- vault kv put homelab/database \
  username=dbadmin \
  password=$(openssl rand -base64 32)

kubectl exec -n vault vault-0 -- vault kv put homelab/grafana \
  password=$(openssl rand -base64 32)

# Create policy for reading secrets
kubectl exec -n vault vault-0 -- vault policy write homelab-read - <<EOF
path "homelab/data/*" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes role
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/homelab \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=trusted,dmz,monitoring \
  policies=homelab-read \
  ttl=24h
```

### **11.3 Connect External Secrets to Vault**

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: trusted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: dmz
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: monitoring
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: trusted
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "homelab"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "homelab"
          serviceAccountRef:
            name: "external-secrets"
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: dmz
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "homelab"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "homelab"
          serviceAccountRef:
            name: "external-secrets"
---
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: monitoring
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
      path: "homelab"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "homelab"
          serviceAccountRef:
            name: "external-secrets"
EOF
```

### **11.4 Example: Sync Grafana Password from Vault**

```bash
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
  - secretKey: admin-password
    remoteRef:
      key: homelab/grafana
      property: password
EOF

# Verify secret was created
kubectl get secret grafana-admin -n monitoring -o yaml
```

---

## Part 12: Complete Bootstrap Script

Save as `bootstrap-homelab.sh`:

```bash
#!/bin/bash
set -e

echo "=== Homelab Kubernetes Bootstrap ==="
echo ""

# Prerequisites check
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
command -v cilium >/dev/null 2>&1 || { echo "cilium CLI not found"; exit 1; }
command -v flux >/dev/null 2>&1 || { echo "flux CLI not found"; exit 1; }

echo "Step 1: Installing Cilium with Hubble..."
cilium install \
  --version 1.15.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.123.10 \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

echo "Step 2: Waiting for Cilium..."
cilium status --wait

echo "Step 3: Creating namespaces..."
kubectl apply -f namespaces.yaml

echo "Step 4: Applying network policies..."
kubectl apply -f dmz-cilium-policies.yaml
kubectl apply -f trusted-cilium-policies.yaml
kubectl apply -f untrusted-cilium-policies.yaml

echo "Step 5: Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
sleep 30
kubectl apply -f metallb-config.yaml

echo "Step 6: Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=300s
kubectl apply -f letsencrypt-issuers.yaml

echo "Step 7: Bootstrapping Flux..."
flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=homelab-gitops \
  --branch=main \
  --path=clusters/homelab \
  --personal

echo ""
echo "=== Bootstrap Complete! ==="
echo ""
echo "Next steps:"
echo "1. Access Hubble UI: cilium hubble ui"
echo "2. Initialize Vault: kubectl exec -n vault vault-0 -- vault operator init"
echo "3. Configure secrets in Vault"
echo "4. Deploy your applications via Flux"
echo ""
echo "Useful commands:"
echo "  kubectl get nodes"
echo "  flux get all"
echo "  cilium status"
echo "  hubble observe"
```

---

## Part 13: Verification & Testing

### **13.1 Verify All Components**

```bash
# Check nodes
kubectl get nodes

# Check all pods
kubectl get pods -A

# Check Flux resources
flux get all

# Check Cilium status
cilium status

# Check network policies
kubectl get cnp -A

# Check Traefik LoadBalancer
kubectl get svc -n traefik

# Check Vault status
kubectl exec -n vault vault-0 -- vault status
```

### **13.2 Test Network Isolation**

```bash
# Test from DMZ (should block home network)
kubectl run test-dmz --image=nicolaka/netshoot -n dmz --rm -it -- bash
# Inside pod:
curl http://192.168.123.1  # Should timeout
curl https://google.com     # Should work

# Test from Trusted (should allow home network)
kubectl run test-trusted --image=nicolaka/netshoot -n trusted --rm -it -- bash
# Inside pod:
curl http://192.168.123.1  # Should work

# Watch flows in Hubble UI
cilium hubble ui
```

### **13.3 Deploy Test Application**

```bash
# Create test app in DMZ
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: dmz
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      nodeSelector:
        workload-type: dmz
      tolerations:
      - key: dmz
        operator: Equal
        value: "true"
        effect: NoSchedule
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: dmz
spec:
  selector:
    app: nginx-test
  ports:
  - port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: nginx-test
  namespace: dmz
spec:
  entryPoints:
  - websecure
  routes:
  - match: Host(\`test.home.local\`)
    kind: Rule
    services:
    - name: nginx-test
      port: 80
  tls:
    certResolver: letsencrypt-staging
EOF

# Test access
curl -H "Host: test.home.local" http://192.168.123.100
```

---

## Summary: What You've Built

✅ **Network Isolation:** 4 security zones (Management, Trusted, DMZ, Untrusted) with software VLANs
✅ **Kubernetes Cluster:** k3s with 1 control plane + 3 workers (14 vCPU, 28GB RAM)
✅ **CNI:** Cilium with eBPF for high performance + WireGuard encryption
✅ **Observability:** Hubble UI for real-time network visualization
✅ **Network Policies:** Zone-based isolation preventing lateral movement
✅ **GitOps:** Flux CD managing all infrastructure declaratively
✅ **Ingress:** Traefik on DMZ nodes with automatic SSL via Let's Encrypt
✅ **Secrets:** HashiCorp Vault + External Secrets Operator
✅ **Monitoring:** Prometheus + Grafana stack
✅ **Load Balancing:** MetalLB providing IPs from home network

**Security Benefits:**
- Compromised DMZ container cannot access home network (192.168.123.0/24)
- Untrusted workloads have internet-only access
- All pod-to-pod traffic encrypted with WireGuard
- Network policies enforced at kernel level (eBPF)
- Secrets never committed to Git
- Full audit trail of network flows via Hubble

**Next Steps:**
1. Deploy your applications to appropriate namespaces
2. Set up automated backups (Velero or Proxmox Backup Server)
3. Configure alerting in Grafana
4. Add monitoring dashboards for Cilium/Hubble metrics
5. Implement GitOps workflows for application deployments

Your homelab is now a production-grade platform! 🚀

rene-kschamer_sap: Is MetalLB necessary?

GitHub Copilot: No, MetalLB is **not strictly necessary** for your setup. Here are your options:

## Option 1: Without MetalLB (Simpler)

**Use NodePort services:**

```yaml
# Traefik without LoadBalancer
service:
  type: NodePort
  nodePorts:
    web: 30080
    websecure: 30443
```

**Then configure FritzBox port forwarding:**
```
External 80  → 192.168.123.22:30080  (DMZ worker IP)
External 443 → 192.168.123.22:30443  (DMZ worker IP)
```

**Pros:**
- Simpler setup, one less component
- No IP pool management needed
- Works immediately

**Cons:**
- Non-standard ports (30080/30443) on nodes
- Need to update FritzBox if worker IP changes
- Can only forward to one worker node (no automatic failover)

## Option 2: With MetalLB (Recommended)

**Pros:**
- Standard ports (80/443)
- Single virtual IP (192.168.123.100) that floats between nodes
- Clean separation: FritzBox forwards to .100, MetalLB handles routing
- If DMZ worker dies, MetalLB moves IP to another node automatically
- More services can get LoadBalancer IPs (databases, etc.)

**Cons:**
- Additional component to manage
- Uses 1-2 IPs from your home network

## Recommendation for Your Setup

**Keep MetalLB** because:

1. **High Availability:** If your DMZ worker crashes, MetalLB automatically assigns the IP to another node
2. **Clean Architecture:** FritzBox → 192.168.123.100 (virtual IP) is cleaner than → 192.168.123.22 (physical node)
3. **Future Flexibility:** Easy to expose other services (e.g., Minecraft server, database)
4. **Production-Like:** MetalLB is standard in bare-metal Kubernetes

However, if you want to **simplify initially**, you can skip MetalLB and use NodePort, then add MetalLB later when you need it. The migration is straightforward:

```bash
# Change service type
kubectl patch svc traefik -n traefik -p '{"spec":{"type":"NodePort"}}'

# Later, reinstall with LoadBalancer type after adding MetalLB
```

**TL;DR:** MetalLB isn't mandatory, but it's worth the small complexity for the reliability and flexibility it provides. For a homelab learning environment, I'd keep it.

rene-kschamer_sap: Okay. Can I also use VaultWarden to manage secrets instead of Hashicorp's Vault?

GitHub Copilot: **No, Vaultwarden cannot replace HashiCorp Vault** for Kubernetes secrets management.

## Key Differences

**Vaultwarden:**
- Password manager for humans (Bitwarden-compatible)
- Stores passwords, TOTP codes, credit cards
- Web UI for manual access
- No Kubernetes integration
- No API for programmatic secret injection

**HashiCorp Vault:**
- Secrets management for applications/infrastructure
- API-first design for automation
- Kubernetes auth backend
- Dynamic secrets generation
- Secret rotation and leasing
- Integrates with External Secrets Operator

## What You Could Do

**Use BOTH:**

1. **Vaultwarden** - Store your personal credentials:
   - Vault root token
   - Vault unseal keys
   - SSH keys
   - API tokens (GitHub, etc.)
   - Admin passwords

2. **HashiCorp Vault** - Store application secrets:
   - Database passwords
   - API keys for services
   - TLS certificates
   - OAuth client secrets

## Alternative: Skip Vault Entirely

If HashiCorp Vault feels too heavy, simpler alternatives:

### **Option 1: Sealed Secrets (Simplest)**

```bash
# Install Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Install kubeseal CLI
brew install kubeseal

# Create sealed secret (can commit to Git safely)
kubectl create secret generic db-creds \
  --from-literal=password=SuperSecret123 \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-db-creds.yaml

# Commit to Git - it's encrypted!
git add sealed-db-creds.yaml
```

**Pros:**
- Very simple
- Secrets encrypted in Git
- No external dependencies

**Cons:**
- No secret rotation
- No dynamic secrets
- Sealed secret controller has the master key

### **Option 2: SOPS (Mozilla)**

```bash
# Encrypt secrets with age or GPG
brew install sops age

# Generate age key
age-keygen -o key.txt

# Encrypt secret
sops --encrypt --age $(cat key.txt | grep public) secret.yaml > secret.enc.yaml

# Flux can decrypt automatically
```

### **Option 3: External Secrets + Vaultwarden?**

Technically possible but hacky:
- Vaultwarden has an unofficial API
- External Secrets Operator doesn't support it natively
- Would need custom webhook provider

**Not recommended** - too fragile for automation.

## Recommendation for Your Homelab

**Start Simple → Add Complexity:**

1. **Phase 1 (Week 1):** Use Kubernetes native secrets
   ```bash
   kubectl create secret generic db-pass --from-literal=password=changeme
   ```

2. **Phase 2 (Month 1):** Add Sealed Secrets for GitOps
   - Encrypt secrets before committing to Git

3. **Phase 3 (Month 2+):** Add HashiCorp Vault when you need:
   - Dynamic database credentials
   - Secret rotation
   - Multiple teams/namespaces with different access

**For your personal passwords/tokens:** Use Vaultwarden separately! Store your Vault unseal keys, root token, and SSH keys there.

## Updated Architecture (Without Vault)

```yaml
# Use Sealed Secrets instead
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  encryptedData:
    admin-password: AgBpT8CnK... # Encrypted, safe to commit
```

**TL;DR:** Vaultwarden is for humans, Vault is for applications. Use Vaultwarden to store your Vault keys, but you can't replace Vault with it. For a simpler homelab, use **Sealed Secrets** instead of HashiCorp Vault.

rene-kschamer_sap: Okay. Summarize again, but include a guide how to transition step by step from the existing approach using a single Docker node to the K8s-based solution

GitHub Copilot: Of course. Here is the complete and final guide, summarizing the target architecture and providing a step-by-step migration plan from your existing single Docker host.

# Final Guide: Secure Kubernetes Homelab on Proxmox

## 1. Final Architecture Overview

This guide outlines a secure, multi-zone Kubernetes homelab built on your Proxmox VE system, managed declaratively with GitOps.

*   **Virtualization:** Proxmox VE (16 CPU, 32GB RAM, 1TB SSD).
*   **Network Isolation:**
    *   **Proxmox Linux Bridges:** Creates software-defined VLANs (`vmbr0` for management, `vmbr1` for trusted, `vmbr2` for DMZ, `vmbr3` for untrusted).
    *   **FritzBox Router:** Acts as the main gateway (192.168.123.1), forwarding ports 80/443 to the cluster's ingress.
*   **Kubernetes Cluster:**
    *   **Distribution:** k3s (lightweight, production-ready).
    *   **Nodes:** 4 VMs across security zones (1 Control Plane, 1 Trusted Worker, 1 DMZ Worker, 1 Untrusted Worker).
*   **Core Kubernetes Components:**
    *   **Networking (CNI):** **Cilium** with eBPF for high-performance networking and security.
    *   **Observability:** **Hubble** for real-time network flow visualization and troubleshooting.
    *   **Ingress:** **Traefik** running on the DMZ node to handle all incoming traffic.
    *   **Load Balancing:** **MetalLB** to provide a stable, virtual IP for Traefik from your home network (e.g., `192.168.123.100`).
    *   **Secrets Management:**
        *   **Sealed Secrets:** For encrypting Kubernetes secrets so they can be safely stored in a public Git repository.
        *   **Vaultwarden:** (Self-hosted separately) To store your personal master keys, like the private key for Sealed Secrets.
    *   **GitOps:** **Flux CD** to automatically sync your cluster's state with a Git repository.
    *   **TLS Certificates:** **cert-manager** for automatic fetching and renewal of Let's Encrypt certificates.
*   **Security Posture:**
    *   **Network Segmentation:** A compromised DMZ container cannot access your trusted network or home devices.
    *   **Least Privilege:** Network policies deny all traffic by default, only allowing what is explicitly required.
    *   **Encrypted Traffic:** Cilium provides transparent WireGuard encryption for all pod-to-pod communication within the cluster.
    *   **Declarative Security:** All network policies and configurations are stored in Git, providing an audit trail.

---

## 2. Step-by-Step Migration Plan

This plan ensures a gradual and safe transition from your single Docker host to the new Kubernetes cluster with minimal downtime.

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Stop your existing Docker containers and create a full backup of all Docker volumes and configuration files (`docker-compose.yml`, `.env` files, etc.). Store this backup safely.
2.  **Document Services:** Create a list of all services currently running. For each service, document its data volume path, exposed ports, and any environment variables.
3.  **Set Up Git:** Create a new, empty repository on GitHub (e.g., `homelab-k8s-config`). This will be your single source of truth.
4.  **Install Tools:** On your local machine (Mac), install the necessary CLI tools:
    ```bash
    brew install kubectl cilium-cli fluxcd/tap/flux kubeseal
    ```

### **Phase 1: Build the Foundation (No Downtime)**

*Goal: Build the entire new Kubernetes platform while the old Docker host continues to run all your services.*

1.  **Configure Proxmox Networking:** Apply the Linux bridge configuration to your Proxmox host's `/etc/network/interfaces` as detailed in the previous messages. Reboot the host to apply.
2.  **Create and Configure VMs:** Create the Ubuntu cloud-init template and clone the four VMs (`k3s-control-01`, `k3s-worker-trusted`, `k3s-worker-dmz`, `k3s-worker-untrusted`) with their respective network and resource configurations.
3.  **Install k3s Cluster:**
    *   Install the k3s control plane on `k3s-control-01` **without the default CNI** (`--flannel-backend=none`).
    *   Join the three worker nodes to the cluster.
4.  **Bootstrap the Cluster:** From your local machine, run the bootstrap process:
    *   Install **Cilium + Hubble**.
    *   Install **MetalLB** and configure its IP pool (`192.168.123.100-192.168.123.110`).
    *   Install **cert-manager** and configure the Let's Encrypt `ClusterIssuer`.
    *   Install **Sealed Secrets**. Fetch the master public key, which you will use to encrypt secrets. Store the private key securely in Vaultwarden.
    *   Bootstrap **Flux CD**, pointing it to your new Git repository.

At the end of this phase, you have a fully functional, empty Kubernetes cluster. Your services are still running uninterrupted on the old Docker host.

### **Phase 2: Deploy Core Services via GitOps (No Downtime)**

*Goal: Use Flux to deploy the core platform services to your new cluster.*

1.  **Structure Your Git Repo:** Create directories in your Git repo for `infrastructure` and `apps`.
2.  **Deploy Traefik:** Add the Helm chart configuration for Traefik to your Git repo. Configure it to use MetalLB and run on the DMZ node. Push to Git and let Flux deploy it. Verify it gets the IP `192.168.123.100`.
3.  **Deploy Monitoring:** Add the `kube-prometheus-stack` Helm chart to your Git repo. Configure Grafana with an IngressRoute. Push and let Flux deploy.
4.  **Configure FritzBox:** Change your FritzBox port forwarding rules (80/443) to point to the new Traefik IP (`192.168.123.100`). **Your services will go down at this point if you haven't migrated them.** A better approach is to use a temporary domain for testing or do the cutover during a maintenance window. For a seamless transition, you can point a test domain to the new IP to verify services before changing the main DNS.

### **Phase 3: Migrate Applications One by One (Minimal Downtime per Service)**

*Goal: Move each service from Docker to Kubernetes individually.*

**For each application, repeat the following steps (start with a simple, stateless one first):**

1.  **Convert & Adapt:**
    *   Use a tool like `kompose` (`brew install kompose`) to convert your `docker-compose.yml` service block into Kubernetes YAML manifests (`kompose convert`).
    *   This gives you a starting point. Now, adapt these manifests:
        *   **Deployment:** Add `nodeSelector` and `tolerations` to schedule the pod on the correct node (`trusted`, `dmz`).
        *   **Service:** Ensure it's a `ClusterIP` service, as Traefik will handle external access.
        *   **Persistence:** Create a `PersistentVolumeClaim` for the service's data.
        *   **Ingress:** Create a `Traefik.io/v1alpha1 IngressRoute` to expose the service through Traefik.
        *   **Secrets:** For any secrets (API keys, passwords), create a standard Kubernetes `Secret` manifest. Then, encrypt it into a `SealedSecret` using the `kubeseal` CLI. Delete the plain-text secret file.

2.  **Deploy to Kubernetes:**
    *   Commit the new manifests (`Deployment`, `Service`, `PersistentVolumeClaim`, `IngressRoute`, `SealedSecret`) to your GitOps repository.
    *   Let Flux deploy the application. It will be running in Kubernetes but not yet receiving live data.

3.  **Migrate Data (Downtime for this service begins):**
    *   Stop the service on your old Docker host (`docker-compose stop <service_name>`).
    *   Use `rsync` or `scp` to copy the data from the Docker volume on the old host to a temporary path on one of your Proxmox nodes (e.g., `/tmp/migration_data`).
    *   Find the running pod in Kubernetes (`kubectl get pods -n <namespace>`).
    *   Copy the data from the node into the pod's persistent volume:
        ```bash
        kubectl cp /tmp/migration_data <namespace>/<pod-name>:/path/to/data
        ```

4.  **Test & Cutover:**
    *   Verify the service is running correctly in Kubernetes by checking logs and accessing it internally.
    *   If you used a temporary domain, test it. If not, you can now be confident it will work. If you haven't already, ensure your main DNS points to the Traefik IP.
    *   Access the service via its public domain and confirm everything works as expected.

5.  **Decommission Old Service:**
    *   Once you are confident the Kubernetes version is stable, remove the service's definition from your old `docker-compose.yml` file.
    *   Run `docker-compose up -d` to apply the change. The service is now fully migrated.

**Migration Order:**
*   **Stateless services first:** Simple web apps, utility containers.
*   **Services with simple state:** Applications with a file-based database or config files.
*   **Complex services last:** Databases (PostgreSQL, MariaDB), applications with critical, hard-to-migrate state.

### **Phase 4: Decommission the Old Docker Host**

1.  **Final Verification:** After all services have been migrated and have been running stably for a week, perform a final check.
2.  **Shutdown:** Gracefully shut down the old Docker VM in Proxmox.
3.  **Wait:** Keep the VM turned off for another week. This is a "cooling-off" period to ensure you didn't miss anything.
4.  **Final Backup & Deletion:** Create a final backup of the shutdown VM. Once the backup is complete, you can delete the VM and its disks from Proxmox to reclaim the resources.

You have now fully transitioned to a secure, resilient, and observable Kubernetes-based homelab.

rene-kschamer_sap: Summarize everything in a single document so that I can save it easily

GitHub Copilot: Of course. Here is the complete, self-contained guide to building your secure Kubernetes homelab on Proxmox, including the step-by-step migration plan.

---

# **Complete Guide: Building a Secure Kubernetes Homelab on Proxmox**

## **1. Final Architecture Overview**

This document outlines a secure, multi-zone Kubernetes homelab built on your Proxmox VE system (16 CPU, 32GB RAM, 1TB SSD), managed declaratively with GitOps.

*   **Virtualization:** Proxmox VE.
*   **Network Isolation:**
    *   **Proxmox Linux Bridges:** Creates software-defined VLANs for isolated security zones (`vmbr0` for management, `vmbr1` for trusted services, `vmbr2` for the DMZ, `vmbr3` for untrusted experiments).
    *   **FritzBox Router:** Your main gateway (192.168.123.1), forwarding external web traffic (ports 80/443) to the cluster's ingress.
*   **Kubernetes Cluster:**
    *   **Distribution:** **k3s** (lightweight, production-ready, and easy to manage).
    *   **Nodes:** 4 dedicated VMs across the security zones (1 Control Plane, 1 Trusted Worker, 1 DMZ Worker, 1 Untrusted Worker).
*   **Core Kubernetes Components:**
    *   **Networking (CNI):** **Cilium** with eBPF for high-performance, kernel-level networking and security enforcement.
    *   **Observability:** **Hubble** (integrated with Cilium) for real-time network flow visualization and troubleshooting.
    *   **Ingress Controller:** **Traefik**, running on the dedicated DMZ node, to handle all incoming HTTP/S traffic.
    *   **Load Balancing:** **MetalLB** to provide a stable, virtual IP for Traefik from your home network (e.g., `192.168.123.100`), enabling high availability.
    *   **Secrets Management:**
        *   **Sealed Secrets:** For encrypting Kubernetes secrets, allowing them to be safely stored in a public Git repository.
        *   **Vaultwarden:** A self-hosted password manager (run separately) to securely store your master keys, such as the private key for Sealed Secrets.
    *   **GitOps:** **Flux CD** to automatically synchronize your cluster's state with a dedicated Git repository, making your infrastructure declarative and auditable.
    *   **TLS Certificates:** **cert-manager** for automatic fetching, renewal, and management of Let's Encrypt TLS certificates for your services.
*   **Security Posture:**
    *   **Zero-Trust Networking:** Network policies deny all traffic by default. Communication is only allowed if explicitly defined.
    *   **Defense in Depth:** A compromised public-facing container in the DMZ is firewalled from your trusted network and internal home devices.
    *   **Encrypted Traffic:** Cilium provides transparent WireGuard encryption for all pod-to-pod communication within the cluster.
    *   **Declarative Security:** All network policies and security configurations are stored as code in Git, providing a clear audit trail and version history.

---

## **2. Step-by-Step Migration Plan**

This plan ensures a gradual and safe transition from your single Docker host to the new Kubernetes cluster with minimal downtime for your services.

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Stop your existing Docker containers and create a full backup of all Docker volumes and configuration files (`docker-compose.yml`, `.env` files, etc.). Store this backup in a safe, external location.
2.  **Document Services:** Create a spreadsheet or document listing all services you currently run. For each service, note its data volume path, exposed ports, environment variables, and any dependencies.
3.  **Set Up Git:** Create a new, empty repository on GitHub (e.g., `homelab-k8s-config`). This will become the single source of truth for your entire cluster configuration.
4.  **Install Tools:** On your local machine (e.g., your Mac), install the necessary command-line tools:
    ```bash
    brew install kubectl cilium-cli fluxcd/tap/flux kubeseal
    ```

### **Phase 1: Build the Foundation (No Downtime)**

*Goal: Build the entire new Kubernetes platform in parallel while your old Docker host continues to run all your services.*

1.  **Configure Proxmox Networking:** Apply the Linux bridge configuration to your Proxmox host's `/etc/network/interfaces` file to create the `vmbr0`, `vmbr1`, `vmbr2`, and `vmbr3` bridges. Reboot the host to apply the changes.
2.  **Create and Configure VMs:** Create the Ubuntu cloud-init template and clone the four VMs (`k3s-control-01`, `k3s-worker-trusted`, `k3s-worker-dmz`, `k3s-worker-untrusted`) with their respective network and resource configurations as previously detailed.
3.  **Install k3s Cluster:**
    *   Install the k3s control plane on `k3s-control-01` **without the default CNI** by using the `--flannel-backend=none` flag.
    *   Join the three worker nodes to the cluster using the token from the control plane.
4.  **Bootstrap the Cluster:** From your local machine, run the bootstrap process for the core components:
    *   Install **Cilium + Hubble**.
    *   Install **MetalLB** and configure its IP address pool (e.g., `192.168.123.100-192.168.123.110`).
    *   Install **cert-manager** and configure the Let's Encrypt `ClusterIssuer`.
    *   Install the **Sealed Secrets** controller. Fetch the master public key, which you will use to encrypt secrets, and store the private key securely in Vaultwarden.
    *   Bootstrap **Flux CD**, pointing it to your new Git repository.

At the end of this phase, you have a fully functional, empty Kubernetes cluster ready for services. Your applications are still running uninterrupted on the old Docker host.

### **Phase 2: Deploy Core Services via GitOps (No Downtime)**

*Goal: Use Flux to deploy the core platform services to your new cluster, managed via Git.*

1.  **Structure Your Git Repo:** Create directories in your Git repo for `infrastructure` and `apps` to organize your manifests.
2.  **Deploy Traefik:** Add the Helm chart configuration for Traefik to your Git repository. Configure it to use MetalLB and run on the DMZ node. Push the changes to Git and let Flux deploy it. Verify it receives the virtual IP `192.168.123.100`.
3.  **Deploy Monitoring:** Add the `kube-prometheus-stack` Helm chart to your Git repo. Configure Grafana with an `IngressRoute` for access. Push and let Flux deploy.
4.  **Prepare for Cutover:** At this stage, do not change your FritzBox rules yet. You can use a temporary domain or edit your local hosts file to point your service domains to the new Traefik IP (`192.168.123.100`) for testing purposes.

### **Phase 3: Migrate Applications One by One (Minimal Downtime per Service)**

*Goal: Move each service from the old Docker host to the new Kubernetes cluster individually.*

**For each application, repeat the following steps (start with a simple, stateless one first):**

1.  **Convert & Adapt Manifests:**
    *   Use a tool like `kompose` (`brew install kompose`) to get a baseline conversion of your `docker-compose.yml` service block into Kubernetes YAML manifests (`kompose convert`).
    *   Adapt these generated manifests for your new architecture:
        *   **Deployment:** Add `nodeSelector` and `tolerations` to schedule the pod on the correct node (`trusted` or `dmz`).
        *   **Service:** Ensure it's a `ClusterIP` type service.
        *   **Persistence:** Create a `PersistentVolumeClaim` for the service's data.
        *   **Ingress:** Create a `Traefik.io/v1alpha1 IngressRoute` to expose the service through Traefik with TLS.
        *   **Secrets:** For any secrets (API keys, passwords), create a standard Kubernetes `Secret` manifest. Then, encrypt it into a `SealedSecret` using the `kubeseal` CLI. Delete the plain-text secret file before committing.

2.  **Deploy to Kubernetes:**
    *   Commit the new manifests (`Deployment`, `Service`, `PersistentVolumeClaim`, `IngressRoute`, `SealedSecret`) to your GitOps repository.
    *   Let Flux deploy the application. It will now be running in Kubernetes but not yet receiving live data.

3.  **Migrate Data (Downtime for this specific service begins):**
    *   Stop the service on your old Docker host (`docker-compose stop <service_name>`).
    *   Use `rsync` or `scp` to copy the data from the Docker volume on the old host to a temporary path on one of your Proxmox nodes (e.g., `/tmp/migration_data`).
    *   Find the running pod in Kubernetes (`kubectl get pods -n <namespace>`).
    *   Copy the data from the node into the pod's persistent volume:
        ```bash
        kubectl cp /tmp/migration_data <namespace>/<pod-name>:/path/to/data
        ```

4.  **Test & Cutover:**
    *   Verify the service is running correctly in Kubernetes by checking its logs and accessing it internally.
    *   **This is the cutover point.** Update your FritzBox port forwarding rules (80/443) to point to the new Traefik IP (`192.168.123.100`).
    *   Access the service via its public domain and confirm everything works as expected.

5.  **Decommission Old Service:**
    *   Once you are confident the Kubernetes version is stable, remove the service's definition from your old `docker-compose.yml` file.
    *   Run `docker-compose up -d` to apply the change. The service is now fully migrated.

**Recommended Migration Order:**
1.  **Stateless services first:** Simple web apps, utility containers.
2.  **Services with simple state:** Applications with a file-based database or config files.
3.  **Complex services last:** Databases (PostgreSQL, MariaDB), applications with critical, hard-to-migrate state.

### **Phase 4: Decommission the Old Docker Host**

1.  **Final Verification:** After all services have been migrated and have been running stably for a week, perform a final check to ensure nothing was missed.
2.  **Shutdown:** Gracefully shut down the old Docker VM in Proxmox.
3.  **Wait:** Keep the VM turned off for another week. This is a "cooling-off" period to ensure you didn't miss anything critical.
4.  **Final Backup & Deletion:** Create a final backup of the shutdown VM. Once the backup is complete and verified, you can delete the VM and its disks from Proxmox to reclaim the resources.

You have now fully transitioned to a secure, resilient, and observable Kubernetes-based homelab.

rene-kschamer_sap: How would I update/upgrade the K8s node operation system and K3s?

GitHub Copilot: Excellent question. Managing updates is critical for security and stability. Here is a guide on how to handle both OS and k3s upgrades for your cluster, using a safe, rolling update strategy.

### **Guiding Principles for Upgrades**

1.  **Backup First:** Before any upgrade, take a snapshot of your VMs in Proxmox. This is your instant rollback plan if anything goes wrong.
2.  **One Node at a Time:** Never upgrade all nodes simultaneously. A rolling update ensures your workloads remain available.
3.  **Read Release Notes:** Always check the k3s release notes for breaking changes or specific upgrade instructions.
4.  **Separate OS and k3s Upgrades:** Do not perform OS patching and k3s version upgrades at the same time. Complete one process fully before starting the other.

---

## **Method 1: Manual Rolling Upgrades**

This method gives you full control and is great for understanding the process.

### **Part A: Updating the Node Operating System (e.g., `apt upgrade`)**

The strategy is to update **worker nodes first**, one by one, and the **control plane last**.

**For each Worker Node (`k3s-worker-trusted`, `k3s-worker-dmz`, etc.):**

1.  **Cordon the Node:** Mark the node as unschedulable. This prevents new pods from being placed on it.
    ```bash
    # From your local machine
    kubectl cordon k3s-worker-trusted
    ```

2.  **Drain the Node:** Safely evict all running pods from the node. The Kubernetes scheduler will move them to other available worker nodes.
    ```bash
    kubectl drain k3s-worker-trusted --ignore-daemonsets --delete-emptydir-data
    ```

3.  **Perform the OS Update:** SSH into the node and run the system package updates.
    ```bash
    # On the worker node VM
    ssh k3sadmin@192.168.123.21
    sudo apt update
    sudo apt upgrade -y
    sudo reboot
    ```

4.  **Uncordon the Node:** Once the node has rebooted and is back online, mark it as schedulable again.
    ```bash
    # From your local machine
    kubectl uncordon k3s-worker-trusted
    ```

5.  **Verify:** Wait a minute and check that the node has returned to a `Ready` state.
    ```bash
    kubectl get nodes
    ```

**Repeat these steps for every worker node.**

**Finally, for the Control Plane Node (`k3s-control-01`):**

Follow the exact same `cordon`, `drain`, `apt upgrade`, `reboot`, and `uncordon` process. The cluster's control plane will be briefly unavailable while the node reboots, but your running workloads on other nodes will not be affected.

### **Part B: Upgrading the k3s Version**

The strategy here is the **opposite** of OS updates: upgrade the **control plane first**, then the **workers**.

1.  **Upgrade the Control Plane:**
    *   SSH into the control plane node (`k3s-control-01`).
    *   Run the k3s installation script, specifying the target version. The script handles the upgrade process automatically.
        ```bash
        # On the control plane VM
        ssh k3sadmin@192.168.123.10
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.4+k3s1 sh -
        ```
    *   Verify the control plane node is running the new version.
        ```bash
        # From your local machine
        kubectl get nodes
        # NAME             STATUS  ROLES                 AGE   VERSION
        # k3s-control-01   Ready   control-plane,master  ...   v1.28.4+k3s1
        ```

2.  **Upgrade Worker Nodes (One by One):**
    *   Follow the same `cordon` and `drain` procedure as the OS update to safely move workloads off the worker node.
        ```bash
        kubectl cordon k3s-worker-trusted
        kubectl drain k3s-worker-trusted --ignore-daemonsets --delete-emptydir-data
        ```
    *   SSH into the worker node.
    *   Run the k3s installation script. It will detect it's a worker and perform the upgrade.
        ```bash
        # On the worker node VM
        ssh k3sadmin@192.168.123.21
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.4+k3s1 sh -
        sudo reboot
        ```
    *   `uncordon` the node to bring it back into service.
        ```bash
        kubectl uncordon k3s-worker-trusted
        ```
    *   Verify the node has rejoined the cluster with the new version. Repeat for all other workers.

---

## **Method 2: Automated Upgrades with System Upgrade Controller (The GitOps Way)**

This is the recommended, production-grade approach. It automates the manual process above in a declarative, Kubernetes-native way that fits perfectly with Flux.

1.  **Deploy the System Upgrade Controller:**
    *   Add this manifest to your GitOps repository (e.g., in `infrastructure/base/system-upgrade-controller/`).
        ```yaml
        # system-upgrade-controller.yaml
        apiVersion: v1
        kind: Namespace
        metadata:
          name: system-upgrade
        ---
        apiVersion: v1
        kind: ServiceAccount
        metadata:
          name: system-upgrade
          namespace: system-upgrade
        ---
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: system-upgrade
        subjects:
        - kind: ServiceAccount
          name: system-upgrade
          namespace: system-upgrade
        roleRef:
          kind: ClusterRole
          name: cluster-admin
          apiGroup: rbac.authorization.k8s.io
        ---
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: system-upgrade-controller
          namespace: system-upgrade
        spec:
          selector:
            matchLabels:
              upgrade.cattle.io/controller: system-upgrade-controller
          template:
            metadata:
              labels:
                upgrade.cattle.io/controller: system-upgrade-controller
            spec:
              serviceAccountName: system-upgrade
              containers:
              - name: system-upgrade-controller
                image: rancher/system-upgrade-controller:v0.13.4
                env:
                - name: SYSTEM_UPGRADE_CONTROLLER_NAME
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.name
                - name: SYSTEM_UPGRADE_CONTROLLER_NAMESPACE
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.namespace
                volumeMounts:
                - name: db
                  mountPath: /var/lib/rancher/etc/
              volumes:
              - name: db
                hostPath:
                  path: /var/lib/rancher/k3s/server/db
                  type: Directory
        ```
    *   Commit and let Flux deploy it.

2.  **Perform a k3s Upgrade via a `Plan`:**
    *   To upgrade your cluster, you simply create a `Plan` manifest in your Git repo. The controller will see it and execute the rolling upgrade automatically.
    *   Create a file (e.g., `apps/upgrade-plans/k3s-v1.28.4.yaml`):
        ```yaml
        # k3s-upgrade-plan.yaml
        apiVersion: upgrade.cattle.io/v1
        kind: Plan
        metadata:
          name: k3s-upgrade
          namespace: system-upgrade
        spec:
          # The k3s version to upgrade to
          version: v1.28.4+k3s1
          concurrency: 1 # Upgrade one node at a time

          # First, upgrade the control plane
          nodeSelector:
            matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: In
              values:
              - "true"

          # Then, upgrade the workers
          upgrade:
            image: rancher/k3s-upgrade
        ---
        # This second part of the plan runs AFTER the control plane is done
        apiVersion: upgrade.cattle.io/v1
        kind: Plan
        metadata:
          name: k3s-worker-upgrade
          namespace: system-upgrade
        spec:
          # This plan depends on the control plane plan succeeding
          prepare:
            image: rancher/k3s-upgrade
            args: ["prepare", "k3s-upgrade"]

          version: v1.28.4+k3s1
          concurrency: 1

          # Select all nodes that are NOT the control plane
          nodeSelector:
            matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: NotIn
              values:
              - "true"

          upgrade:
            image: rancher/k3s-upgrade
        ```
    *   **To trigger the upgrade, commit this file to your Git repo.** Flux will apply it, and the `system-upgrade-controller` will begin the safe, automated rolling upgrade.
    *   You can monitor the progress with `kubectl get plans -n system-upgrade -w`.
    *   Once the upgrade is complete, you can delete the `Plan` file from your repo.

This automated method is far superior for long-term management, as it turns a manual, multi-step process into a single Git commit.

rene-kschamer_sap: How would the setup of the node VMs look like if Talos Linux would be used?

GitHub Copilot: Of course. Using Talos Linux changes the node setup philosophy entirely. Instead of configuring a general-purpose OS, you generate a declarative configuration file that defines the entire node. It's a more streamlined, secure, and API-driven approach.

Here’s how the setup of the node VMs would look with Talos Linux.

### **Core Concepts of Talos Linux**

*   **Immutable & Minimal:** The OS is read-only and contains only the components needed to run Kubernetes. There is no shell, no SSH, and no package manager.
*   **API-Driven:** All interaction with the nodes happens through the `talosctl` CLI, which communicates with a gRPC API on each node.
*   **Declarative Configuration:** Each node is configured with a single YAML file that defines its role, network settings, and cluster information. This file is provided at boot time.
*   **Built-in HA:** Talos manages the control plane virtual IP (VIP) for you, removing the need for external tools like `kube-proxy` in some setups.

---

### **Step 1: Install `talosctl` CLI**

First, install the command-line tool on your local machine (Mac).

```bash
brew install talosctl
```

---

### **Step 2: Generate Machine Configuration Files**

Instead of installing an OS and then running scripts, you first generate configuration files for your entire cluster.

1.  **Create a directory for your cluster configuration:**
    ```bash
    mkdir my-talos-cluster
    cd my-talos-cluster
    ```

2.  **Generate the configuration files:**
    *   `--cluster-name`: A unique name for your cluster.
    *   `--endpoint`: The Virtual IP (VIP) that will be shared by your control plane nodes. This IP must be on your management network (`192.168.123.0/24`) and not be in use.
    *   `--with-kubespan`: Enables an encrypted WireGuard-based overlay network.

    ```bash
    # This command generates controlplane.yaml, worker.yaml, and talosconfig
    talosctl gen config my-homelab-cluster https://192.168.123.30:6443 \
      --with-kubespan \
      --install-image factory.talos.dev/installer/v1.7.0-alpha.2 # Check for latest version
    ```

    This will create three important files:
    *   `controlplane.yaml`: The configuration for your control plane nodes.
    *   `worker.yaml`: The configuration for your worker nodes.
    *   `talosconfig`: The `kubeconfig`-like file for `talosctl` to access the cluster API.

3.  **Edit the Machine Configs:**
    You must now edit `controlplane.yaml` and `worker.yaml` to assign static IPs and network settings for each node.

    **Example: `controlplane.yaml`**
    ```yaml
    # ... (machine type and version)
    machine:
      network:
        interfaces:
          - interface: eth0
            dhcp: false
            addresses:
              - 192.168.123.10/24 # Static IP for the first control plane node
            routes:
              - network: 0.0.0.0/0
                gateway: 192.168.123.1
            vip:
              ip: 192.168.123.30 # The shared VIP
        nameservers:
          - 192.168.123.1
    # ... (rest of the file)
    ```
    You would create copies of these files and edit them for each specific node (`controlplane-1.yaml`, `worker-trusted.yaml`, etc.), ensuring each has a unique static IP.

---

### **Step 3: Proxmox VM and Template Setup**

The VM setup is much simpler because you don't need to install an OS.

1.  **Download the Talos ISO:**
    On your Proxmox host, download the ISO for bare-metal installations.
    ```bash
    # On Proxmox host
    wget https://factory.talos.dev/image/b57422a8777a3139a733403a4599805553103869545836314c739fbf364f704b/v1.7.0-alpha.2/metal-amd64.iso
    # Move it to your ISO storage location
    mv metal-amd64.iso /var/lib/vz/template/iso/
    ```

2.  **Create a VM Template:**
    *   **OS:** Do not use any media.
    *   **System:** `qemu-agent` enabled.
    *   **Hard Disk:** Create a 32GB disk (SCSI or VirtIO Block).
    *   **CPU:** 2 cores.
    *   **Memory:** 4096 MB.
    *   **Network:** VirtIO, connected to `vmbr0`.
    *   **No Cloud-Init Drive.**
    *   Convert this VM to a template.

---

### **Step 4: Create and Boot the Cluster Nodes**

This is the main difference. You provide the machine config via a virtual CD-ROM.

**For the First Control Plane Node (`k3s-control-01`):**

1.  **Clone the Template:** Clone your Talos template to a new VM (e.g., VM ID 101). Adjust CPU/Memory as needed.
2.  **Create a Config ISO:**
    *   On your local machine, you need a tool to create an ISO. On macOS, you can use `hdiutil`.
    *   Create a temporary folder, copy your edited `controlplane-1.yaml` into it, and rename it to `user_data`.
        ```bash
        mkdir cidata
        cp controlplane-1.yaml cidata/user_data
        hdiutil makehybrid -o talos-cp1.iso -hfs -joliet -iso -default-volume-name cidata cidata/
        ```
    *   Upload this `talos-cp1.iso` to your Proxmox ISO storage.
3.  **Configure the VM:**
    *   **Boot Order:** Set the boot order to be the Talos installation ISO first (`metal-amd64.iso`).
    *   **Add a CD/DVD Drive:** Add a second CD-ROM drive and select the config ISO you just uploaded (`talos-cp1.iso`).
4.  **Start the VM:** The VM will boot from the Talos installer, read the configuration from the second CD-ROM, install itself to the hard disk, and then reboot. After rebooting, it will be running with your specified configuration.

**Bootstrap the Cluster:**

Once the first control plane node is up, you must bootstrap the cluster.

1.  **Configure `talosctl`:**
    ```bash
    # Point talosctl to your node and use the generated config
    export TALOSCONFIG=./talosconfig
    talosctl --nodes 192.168.123.10 config endpoint 192.168.123.30
    talosctl --nodes 192.168.123.10 config node 192.168.123.10
    ```

2.  **Run Bootstrap:** This command initializes the etcd cluster.
    ```bash
    talosctl bootstrap --nodes 192.168.123.10
    ```

**For All Other Nodes (Workers):**

Repeat the process:
1.  Clone the template.
2.  Create a config ISO for each worker using its specific `worker-X.yaml` file.
3.  Attach the Talos installer ISO and the worker's config ISO.
4.  Start the VM.

The worker nodes will automatically find and join the bootstrapped control plane.

---

### **Step 5: Accessing Your Cluster**

Once the cluster is up, you can get the Kubernetes config.

```bash
# This merges the new cluster config into your ~/.kube/config
talosctl kubeconfig .
```

Now you can use `kubectl` as usual.
```bash
kubectl get nodes
kubectl get pods -A
```

### **Upgrading with Talos (The Payoff)**

Upgrading is incredibly simple. To upgrade all nodes to a new version, you run a single command:

```bash
# This performs a safe, rolling upgrade of the entire cluster
talosctl upgrade --to factory.talos.dev/installer/v1.7.1
```

### **Summary of Differences: k3s/Ubuntu vs. Talos**

| Feature | k3s on Ubuntu Setup | Talos Linux Setup |
| :--- | :--- | :--- |
| **OS Installation** | Install Ubuntu, run `apt upgrade`, configure networking. | None. Boot from ISO, which installs a pre-built image. |
| **Configuration** | Imperative shell commands (`curl`, `sh`, `apt`). | Declarative YAML file provided at boot. |
| **Node Access** | SSH | `talosctl` API (no shell access). |
| **Bootstrap** | Install k3s on control plane, then join workers. | Generate all configs, boot first node, run `talosctl bootstrap`. |
| **Secrets** | Handled by k3s. | Handled by Talos, stored in the etcd database. |
| **Upgrades** | Manual rolling updates or System Upgrade Controller. | Single `talosctl upgrade` command. |
| **Security** | General-purpose OS; needs hardening. | Immutable, minimal, API-only surface. More secure out-of-the-box. |
| **Flexibility** | High. Can install any package or tool on the node. | Low. The node only runs Kubernetes. (This is a feature). |

rene-kschamer_sap: Okay, give me an updated installation plan and overview for using Talos Linux.

GitHub Copilot: Of course. Here is the complete, updated guide for building your secure homelab using the immutable Talos Linux operating system. This approach enhances security and simplifies cluster management.

---

# **Final Guide: Secure, Immutable Kubernetes Homelab with Talos Linux**

## **1. Final Architecture Overview**

This guide outlines a secure, immutable, and production-grade Kubernetes homelab built on your Proxmox VE system, managed declaratively via its API and GitOps.

*   **Virtualization:** Proxmox VE (16 CPU, 32GB RAM, 1TB SSD).
*   **Operating System:** **Talos Linux**, an immutable, minimal, and API-driven OS designed exclusively for Kubernetes. This eliminates entire classes of vulnerabilities and simplifies management.
*   **Network Isolation:**
    *   **Proxmox Linux Bridges:** Creates software-defined VLANs for isolated security zones (`vmbr0` for management, `vmbr1` for trusted, `vmbr2` for DMZ, `vmbr3` for untrusted).
    *   **FritzBox Router:** Your main gateway (192.168.123.1), forwarding external web traffic (ports 80/443) to the cluster's ingress.
*   **Kubernetes Cluster:**
    *   **Distribution:** A CNCF-certified Kubernetes distribution built into Talos.
    *   **Nodes:** 4 dedicated VMs across the security zones (1 Control Plane, 1 Trusted Worker, 1 DMZ Worker, 1 Untrusted Worker), all running Talos.
*   **Core Kubernetes Components:**
    *   **Networking (CNI):** **Cilium** with eBPF for high-performance networking and security.
    *   **Observability:** **Hubble** (integrated with Cilium) for real-time network flow visualization.
    *   **Ingress Controller:** **Traefik**, running on the dedicated DMZ node, to handle all incoming HTTP/S traffic.
    *   **Load Balancing:** **MetalLB** to provide a stable, virtual IP for Traefik from your home network (e.g., `192.168.123.100`).
    *   **Secrets Management:**
        *   **Sealed Secrets:** For encrypting Kubernetes secrets so they can be safely stored in a public Git repository.
        *   **Vaultwarden:** (Self-hosted separately) To securely store your master keys, like the private key for Sealed Secrets.
    *   **GitOps:** **Flux CD** to automatically synchronize your cluster's state with a dedicated Git repository.
    *   **TLS Certificates:** **cert-manager** for automatic fetching and renewal of Let's Encrypt certificates.
*   **Security & Management Posture:**
    *   **Immutable Infrastructure:** The OS on each node is read-only and cannot be changed, preventing configuration drift and unauthorized modifications.
    *   **API-Driven Management:** There is **no SSH access**. All node management is done securely via the `talosctl` CLI and its gRPC API.
    *   **Declarative Configuration:** The entire state of each node is defined by a single YAML file, making the cluster fully reproducible.
    *   **Minimal Attack Surface:** Talos includes only the necessary components to run Kubernetes, drastically reducing potential vulnerabilities.
    *   **Simplified Upgrades:** The entire Kubernetes cluster (OS and components) can be upgraded with a single, safe, rolling-update command.

---

## **2. Step-by-Step Installation & Migration Plan**

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Create a full backup of your existing Docker volumes and configuration files.
2.  **Document Services:** List all running services, their data paths, ports, and environment variables.
3.  **Set Up Git:** Create a new, empty repository on GitHub (e.g., `homelab-talos-config`).
4.  **Install Tools:** On your local machine, install the necessary CLI tools:
    ```bash
    brew install talosctl kubectl fluxcd/tap/flux kubeseal
    ```

### **Phase 1: Build the Talos Cluster Foundation (No Downtime)**

*Goal: Build the entire new Talos Kubernetes platform while the old Docker host continues to run.*

1.  **Generate Talos Machine Configs:**
    *   Create a directory for your cluster configuration (`mkdir my-talos-cluster && cd my-talos-cluster`).
    *   Generate the base configuration files. The endpoint IP (`192.168.123.30`) will be a stable, virtual IP for the control plane API.
        ```bash
        talosctl gen config my-homelab-cluster https://192.168.123.30:6443
        ```
    *   This creates `controlplane.yaml`, `worker.yaml`, and `talosconfig`.

2.  **Customize Machine Configs for Each Node:**
    *   Create copies of the generated files for each node and edit them to assign static IPs and labels.

    *   **`controlplane-1.yaml`:**
        ```yaml
        # ... (machine config section)
        machine:
          network:
            interfaces:
              - interface: eth0
                dhcp: false
                addresses: [192.168.123.10/24] # Static IP for this node
                routes: [{ network: 0.0.0.0/0, gateway: 192.168.123.1 }]
            nameservers: [192.168.123.1]
        # ...
        ```

    *   **`worker-dmz.yaml`:** Add a second network interface and node labels.
        ```yaml
        machine:
          network:
            interfaces:
              - interface: eth0 # Workload network
                dhcp: false
                addresses: [10.10.30.10/24]
                routes: [{ network: 0.0.0.0/0, gateway: 10.10.30.1 }]
              - interface: eth1 # Management network for k8s components
                dhcp: false
                addresses: [192.168.123.22/24]
            nameservers: [192.168.123.1]
        # Add these labels for scheduling
        node:
          labels:
            workload-type: dmz
            network-zone: dmz
        # Add a taint
        taints:
          - key: dmz
            value: "true"
            effect: NoSchedule
        ```
    *   Create similar customized files for `worker-trusted.yaml` and `worker-untrusted.yaml` with their respective IPs and labels.

3.  **Prepare Proxmox Template & ISOs:**
    *   **Download Talos ISO:** On the Proxmox host, download the `metal-amd64.iso` from the Talos releases page and place it in your ISO storage.
    *   **Create VM Template:** Create a basic VM template with no OS, a 32GB disk, 2+ cores, 4GB+ RAM, and two network devices (one on `vmbr0`, one on `vmbr2`, etc.).
    *   **Create Config ISOs:** For each node, create a specific config ISO containing its YAML file. On macOS:
        ```bash
        # For the DMZ worker
        mkdir cidata-dmz
        cp worker-dmz.yaml cidata-dmz/user_data
        hdiutil makehybrid -o talos-dmz.iso -hfs -joliet -iso -default-volume-name cidata cidata-dmz/
        ```
        Upload each generated `.iso` file to Proxmox.

4.  **Create and Boot Cluster Nodes:**
    *   **For each node:**
        1.  Clone the VM template.
        2.  Attach the main Talos installer ISO to the first CD-ROM drive.
        3.  Attach the node-specific config ISO (e.g., `talos-dmz.iso`) to the second CD-ROM drive.
        4.  Start the VM. It will automatically install Talos using your configuration and reboot.

5.  **Bootstrap the Cluster:**
    *   Once the first control plane node (`192.168.123.10`) is up, bootstrap the cluster from your local machine.
        ```bash
        # Configure talosctl to talk to the new cluster
        export TALOSCONFIG=./talosconfig
        talosctl config endpoint 192.168.123.10 192.168.123.30
        talosctl config node 192.168.123.10

        # Bootstrap the etcd cluster
        talosctl bootstrap -n 192.168.123.10
        ```
    *   Start the other worker VMs. They will automatically join the bootstrapped cluster.

6.  **Get Kubernetes Access:**
    ```bash
    # Merge the new cluster's config into your local kubeconfig
    talosctl kubeconfig .

    # Verify! Nodes should appear one by one.
    kubectl get nodes
    ```

### **Phase 2: Deploy Core Services via GitOps (No Downtime)**

*Goal: Use Flux to deploy all necessary cluster components.*

1.  **Bootstrap Flux:** Point Flux to your new Git repository.
    ```bash
    flux bootstrap github \
      --owner=<your-github-username> \
      --repository=homelab-talos-config \
      --branch=main \
      --path=clusters/homelab \
      --personal
    ```
2.  **Commit Core Component Manifests:** Unlike k3s, Talos is minimal. You must explicitly add everything else. In your Git repo, create `HelmRelease` manifests for:
    *   **Cilium:** (Your CNI is required first).
    *   **MetalLB:** To provide the LoadBalancer IP.
    *   **cert-manager:** For TLS certificates.
    *   **Sealed Secrets:** For secret management.
    *   **Traefik:** Your ingress controller.
    *   **kube-prometheus-stack:** For monitoring.
3.  **Push to Git:** Commit all these manifests to your Git repo. Flux will see them and deploy everything in the correct order (if dependencies are set up). Your cluster will now be fully configured.

### **Phase 3: Migrate Applications One by One (Minimal Downtime per Service)**

*This phase is identical to the previous plan, as application manifests are independent of the underlying OS.*

1.  **Convert & Adapt Manifests:** Use `kompose` to convert `docker-compose.yml` files and adapt them into Kubernetes `Deployment`, `Service`, `PersistentVolumeClaim`, and `IngressRoute` manifests.
2.  **Encrypt and Commit Secrets:** Use `kubeseal` to create `SealedSecret` manifests for your application secrets and commit them to Git.
3.  **Deploy via GitOps:** Commit the application manifests to your Git repo and let Flux deploy them.
4.  **Migrate Data:** Stop the service on the old Docker host, `rsync` the data to a node, and use `kubectl cp` to copy it into the new persistent volume.
5.  **Cutover:** Update your FritzBox port forwarding rules to point to the Traefik IP (`192.168.123.100`).
6.  **Decommission Old Service:** Remove the service from your `docker-compose.yml`.

### **Phase 4: Decommission the Old Docker Host**

1.  **Final Verification:** After all services are stable, perform a final check.
2.  **Shutdown & Wait:** Shut down the old Docker VM and wait a week to ensure nothing was missed.
3.  **Backup & Delete:** Create a final backup of the VM, then delete it from Proxmox.

---

## **3. Upgrades & Maintenance: The Talos Advantage**

Managing and upgrading a Talos cluster is radically simpler.

*   **OS and Kubernetes Upgrades:** To upgrade the entire cluster (both the Talos OS and the Kubernetes version) to a new version, you run a single command. Talos handles the safe, rolling update process automatically.
    ```bash
    # Example: Upgrade the entire cluster to a new version
    talosctl upgrade --to factory.talos.dev/installer/v1.7.1
    ```
*   **Node Configuration Changes:** To change a node's configuration (e.g., add a new label), you edit its YAML file and apply it with `talosctl apply-config`. The node will reboot with the new configuration.

You have now built a highly secure, reproducible, and easy-to-manage Kubernetes homelab.

rene-kschamer_sap: I'm missing the VLAN setup on the Proxmox host. Update the Overview accordingly.

GitHub Copilot: Of course. You are right, a detailed network configuration is crucial. Here is the complete guide, updated to prominently feature the Proxmox host network setup for creating the isolated VLANs.

---

# **Final Guide: Secure, Immutable Kubernetes Homelab with Talos Linux**

## **1. Final Architecture Overview**

This document outlines a secure, immutable, and production-grade Kubernetes homelab built on your Proxmox VE system (16 CPU, 32GB RAM, 1TB SSD), managed declaratively via its API and GitOps.

*   **Virtualization:** Proxmox VE.
*   **Operating System:** **Talos Linux**, an immutable, minimal, and API-driven OS designed exclusively for Kubernetes. This eliminates entire classes of vulnerabilities and simplifies management.
*   **Network Isolation:**
    *   **Proxmox Host Network Configuration:** We will create isolated network segments using **Linux Bridges** on the Proxmox host. This acts as a software-defined VLAN setup, perfect for environments without a managed switch. Each bridge represents a different security zone.
        *   **`vmbr0` (Management):** Connected to your physical network (`192.168.123.0/24`) for Proxmox management and Kubernetes API access.
        *   **`vmbr1` (Trusted):** An isolated network (`10.10.20.0/24`) for internal services. It has NAT access to the internet but is firewalled from other zones.
        *   **`vmbr2` (DMZ):** An isolated network (`10.10.30.0/24`) for public-facing services like the ingress controller. It has NAT access to the internet but is blocked from reaching the trusted or management networks.
        *   **`vmbr3` (Untrusted):** A heavily restricted network (`10.10.40.0/24`) for experiments, with internet-only egress and no access to any internal networks.
    *   **FritzBox Router:** Your main gateway (192.168.123.1), forwarding external web traffic (ports 80/443) to the cluster's ingress IP.
*   **Kubernetes Cluster:**
    *   **Distribution:** A CNCF-certified Kubernetes distribution built directly into Talos.
    *   **Nodes:** 4 dedicated VMs across the security zones (1 Control Plane, 1 Trusted Worker, 1 DMZ Worker, 1 Untrusted Worker), all running Talos. Each worker VM will have dual network interfaces to connect to both the management and its respective isolated network.
*   **Core Kubernetes Components:**
    *   **Networking (CNI):** **Cilium** with eBPF for high-performance, kernel-level networking and security enforcement.
    *   **Observability:** **Hubble** (integrated with Cilium) for real-time network flow visualization.
    *   **Ingress Controller:** **Traefik**, running on the dedicated DMZ node, to handle all incoming HTTP/S traffic.
    *   **Load Balancing:** **MetalLB** to provide a stable, virtual IP for Traefik from your home network (e.g., `192.168.123.100`).
    *   **Secrets Management:**
        *   **Sealed Secrets:** For encrypting Kubernetes secrets, allowing them to be safely stored in a public Git repository.
        *   **Vaultwarden:** (Self-hosted separately) To securely store your master keys, like the private key for Sealed Secrets.
    *   **GitOps:** **Flux CD** to automatically synchronize your cluster's state with a dedicated Git repository.
    *   **TLS Certificates:** **cert-manager** for automatic fetching and renewal of Let's Encrypt TLS certificates.
*   **Security & Management Posture:**
    *   **Immutable Infrastructure:** The OS on each node is read-only and cannot be changed, preventing configuration drift and unauthorized modifications.
    *   **API-Driven Management:** There is **no SSH access**. All node management is done securely via the `talosctl` CLI and its gRPC API.
    *   **Declarative Configuration:** The entire state of each node is defined by a single YAML file, making the cluster fully reproducible.
    *   **Minimal Attack Surface:** Talos includes only the necessary components to run Kubernetes, drastically reducing potential vulnerabilities.
    *   **Simplified Upgrades:** The entire Kubernetes cluster (OS and components) can be upgraded with a single, safe, rolling-update command.

---

## **2. Step-by-Step Installation & Migration Plan**

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Create a full backup of your existing Docker volumes and configuration files.
2.  **Document Services:** List all running services, their data paths, ports, and environment variables.
3.  **Set Up Git:** Create a new, empty repository on GitHub (e.g., `homelab-talos-config`).
4.  **Install Tools:** On your local machine, install the necessary CLI tools:
    ```bash
    brew install talosctl kubectl fluxcd/tap/flux kubeseal
    ```

### **Phase 1: Build the Talos Cluster Foundation (No Downtime)**

*Goal: Build the entire new Talos Kubernetes platform while the old Docker host continues to run.*

1.  **Configure Proxmox Networking:**
    *   SSH into your Proxmox host and edit `/etc/network/interfaces` to match the following configuration. **Replace `enp0s31f6` with your actual physical network interface name.**
        ```bash
        # /etc/network/interfaces

        # Management bridge (connected to FritzBox)
        auto vmbr0
        iface vmbr0 inet static
            address 192.168.123.2/24
            gateway 192.168.123.1
            bridge-ports enp0s31f6
            bridge-stp off
            bridge-fd 0

        # Trusted network bridge (isolated)
        auto vmbr1
        iface vmbr1 inet static
            address 10.10.20.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE

        # DMZ bridge (isolated)
        auto vmbr2
        iface vmbr2 inet static
            address 10.10.30.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE

        # Untrusted bridge (isolated, internet-only)
        auto vmbr3
        iface vmbr3 inet static
            address 10.10.40.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.40.0/24' -o vmbr0 -# /etc/network/interfaces

        # Management bridge (connected to FritzBox)
        auto vmbr0
        iface vmbr0 inet static
            address 192.168.123.2/24
            gateway 192.168.123.1
            bridge-ports enp0s31f6
            bridge-stp off
            bridge-fd 0

        # Trusted network bridge (isolated)
        auto vmbr1
        iface vmbr1 inet static
            address 10.10.20.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE

        # DMZ bridge (isolated)
        auto vmbr2
        iface vmbr2 inet static
            address 10.10.30.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE

        # Untrusted bridge (isolated, internet-only)
        auto vmbr3
        iface vmbr3 inet static
            address 10.10.40.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.40.0/24' -o vmbr0 -

rene-kschamer_sap: @GitHubCopilot Try Again

GitHub Copilot: Of course. You are right, the VLAN setup is a critical piece of the foundation. I have updated the guide to include the specific Proxmox network configuration directly in the overview for clarity.

Here is the complete, updated guide.

---

# **Final Guide: Secure, Immutable Kubernetes Homelab with Talos Linux**

## **1. Final Architecture Overview**

This document outlines a secure, immutable, and production-grade Kubernetes homelab built on your Proxmox VE system, managed declaratively via its API and GitOps.

*   **Virtualization:** Proxmox VE (16 CPU, 32GB RAM, 1TB SSD).
*   **Operating System:** **Talos Linux**, an immutable, minimal, and API-driven OS designed exclusively for Kubernetes. This eliminates entire classes of vulnerabilities and simplifies management.
*   **Network Isolation:**
    *   **Proxmox Software-Defined Networking:** We will create four distinct, isolated networks using **Linux Bridges** on the Proxmox host. This approach acts as a "software VLAN" setup and does not require a managed switch.
        *   `vmbr0`: **Management Network** (192.168.123.0/24) - Connects to your FritzBox LAN. Used for Proxmox management and Kubernetes API access.
        *   `vmbr1`: **Trusted Network** (10.10.20.0/24) - For internal services like Home Assistant. Can initiate traffic to the home LAN.
        *   `vmbr2`: **DMZ Network** (10.10.30.0/24) - For public-facing services like the Traefik ingress. Isolated from the home LAN.
        *   `vmbr3`: **Untrusted Network** (10.10.40.0/24) - For experiments. Completely isolated with internet-only egress.
    *   **Proxmox Host Configuration (`/etc/network/interfaces`):**
        ```bash
        # Management bridge (connected to FritzBox LAN)
        auto vmbr0
        iface vmbr0 inet static
            address 192.168.123.2/24
            gateway 192.168.123.1
            bridge-ports enp0s31f6  # <-- CHANGE THIS to your physical NIC
            bridge-stp off
            bridge-fd 0

        # Trusted network bridge (isolated)
        auto vmbr1
        iface vmbr1 inet static
            address 10.10.20.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.20.0/24' -o vmbr0 -j MASQUERADE

        # DMZ bridge (isolated)
        auto vmbr2
        iface vmbr2 inet static
            address 10.10.30.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE

        # Untrusted bridge (isolated, internet-only)
        auto vmbr3
        iface vmbr3 inet static
            address 10.10.40.1/24
            bridge-ports none
            bridge-stp off
            bridge-fd 0
            post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
            post-up   iptables -t nat -A POSTROUTING -s '10.10.40.0/24' -o vmbr0 -j MASQUERADE
            post-down iptables -t nat -D POSTROUTING -s '10.10.40.0/24' -o vmbr0 -j MASQUERADE
            # Block access from untrusted to any internal network
            post-up   iptables -I FORWARD -i vmbr3 -d '192.168.0.0/16' -j DROP
            post-up   iptables -I FORWARD -i vmbr3 -d '10.0.0.0/8' -j DROP
            post-down iptables -D FORWARD -i vmbr3 -d '192.168.0.0/16' -j DROP
            post-down iptables -D FORWARD -i vmbr3 -d '10.0.0.0/8' -j DROP
        ```
    *   **FritzBox Router:** Your main gateway (192.168.123.1), forwarding external web traffic (ports 80/443) to the cluster's ingress IP.
*   **Kubernetes Cluster:**
    *   **Distribution:** A CNCF-certified Kubernetes distribution built into Talos.
    *   **Nodes:** 4 dedicated VMs across the security zones (1 Control Plane, 1 Trusted Worker, 1 DMZ Worker, 1 Untrusted Worker), all running Talos.
*   **Core Kubernetes Components:**
    *   **Networking (CNI):** **Cilium** with eBPF for high-performance networking and security.
    *   **Observability:** **Hubble** (integrated with Cilium) for real-time network flow visualization.
    *   **Ingress Controller:** **Traefik**, running on the dedicated DMZ node, to handle all incoming HTTP/S traffic.
    *   **Load Balancing:** **MetalLB** to provide a stable, virtual IP for Traefik from your home network (e.g., `192.168.123.100`).
    *   **Secrets Management:**
        *   **Sealed Secrets:** For encrypting Kubernetes secrets so they can be safely stored in a public Git repository.
        *   **Vaultwarden:** (Self-hosted separately) To securely store your master keys, like the private key for Sealed Secrets.
    *   **GitOps:** **Flux CD** to automatically synchronize your cluster's state with a dedicated Git repository.
    *   **TLS Certificates:** **cert-manager** for automatic fetching and renewal of Let's Encrypt certificates.
*   **Security & Management Posture:**
    *   **Immutable Infrastructure:** The OS on each node is read-only and cannot be changed, preventing configuration drift and unauthorized modifications.
    *   **API-Driven Management:** There is **no SSH access**. All node management is done securely via the `talosctl` CLI and its gRPC API.
    *   **Declarative Configuration:** The entire state of each node is defined by a single YAML file, making the cluster fully reproducible.
    *   **Minimal Attack Surface:** Talos includes only the necessary components to run Kubernetes, drastically reducing potential vulnerabilities.
    *   **Simplified Upgrades:** The entire Kubernetes cluster (OS and components) can be upgraded with a single, safe, rolling-update command.

---

## **2. Step-by-Step Installation & Migration Plan**

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Create a full backup of your existing Docker volumes and configuration files.
2.  **Document Services:** List all running services, their data paths, ports, and environment variables.
3.  **Set Up Git:** Create a new, empty repository on GitHub (e.g., `homelab-talos-config`).
4.  **Install Tools:** On your local machine, install the necessary CLI tools:
    ```bash
    brew install talosctl kubectl fluxcd/tap/flux kubeseal
    ```

### **Phase 1: Build the Talos Cluster Foundation (No Downtime)**

*Goal: Build the entire new Talos Kubernetes platform while the old Docker host continues to run.*

1.  **Apply Proxmox Networking:** Edit `/etc/network/interfaces` on your Proxmox host with the configuration from the overview above. **Reboot the host** to apply the changes.
2.  **Generate Talos Machine Configs:**
    *   Create a directory for your cluster configuration (`mkdir my-talos-cluster && cd my-talos-cluster`).
    *   Generate the base configuration files. The endpoint IP (`192.168.123.30`) will be a stable, virtual IP for the control plane API.
        ```bash
        talosctl gen config my-homelab-cluster https://192.168.123.30:6443
        ```
    *   This creates `controlplane.yaml`, `worker.yaml`, and `talosconfig`.

3.  **Customize Machine Configs for Each Node:**
    *   Create copies of the generated files for each node and edit them to assign static IPs and labels as detailed in the previous responses. Each worker node will have two network interfaces: one for its workload network (e.g., `eth0` on `vmbr2` for the DMZ worker) and one for the management network (`eth1` on `vmbr0`).

4.  **Prepare Proxmox Template & ISOs:**
    *   **Download Talos ISO:** On the Proxmox host, download the `metal-amd64.iso` from the Talos releases page and place it in your ISO storage.
    *   **Create VM Template:** Create a basic VM template with no OS, a 32GB disk, and two network devices.
    *   **Create Config ISOs:** For each node, create a specific config ISO containing its customized YAML file (e.g., `talos-dmz.iso`). Upload these to Proxmox.

5.  **Create and Boot Cluster Nodes:**
    *   **For each node:**
        1.  Clone the VM template.
        2.  Attach the main Talos installer ISO to the first CD-ROM drive.
        3.  Attach the node-specific config ISO to the second CD-ROM drive.
        4.  Start the VM. It will automatically install Talos using your configuration and reboot.

6.  **Bootstrap the Cluster:**
    *   Once the first control plane node (`192.168.123.10`) is up, bootstrap the cluster from your local machine.
        ```bash
        export TALOSCONFIG=./talosconfig
        talosctl config endpoint 192.168.123.10 192.168.123.30
        talosctl config node 192.168.123.10
        talosctl bootstrap -n 192.168.123.10
        ```
    *   Start the other worker VMs. They will automatically join the bootstrapped cluster.

7.  **Get Kubernetes Access:**
    ```bash
    talosctl kubeconfig .
    kubectl get nodes
    ```

### **Phase 2: Deploy Core Services via GitOps (No Downtime)**

*Goal: Use Flux to deploy all necessary cluster components.*

1.  **Bootstrap Flux:** Point Flux to your new Git repository.
    ```bash
    flux bootstrap github \
      --owner=<your-github-username> \
      --repository=homelab-talos-config \
      --branch=main \
      --path=clusters/homelab \
      --personal
    ```
2.  **Commit Core Component Manifests:** In your Git repo, create `HelmRelease` manifests for **Cilium**, **MetalLB**, **cert-manager**, **Sealed Secrets**, **Traefik**, and **kube-prometheus-stack**.
3.  **Push to Git:** Commit all these manifests. Flux will deploy everything. Your cluster will now be fully configured.

### **Phase 3: Migrate Applications One by One (Minimal Downtime per Service)**

*This phase is identical to the previous plan, as application manifests are independent of the underlying OS.*

1.  **Convert & Adapt Manifests:** Use `kompose` to convert `docker-compose.yml` files and adapt them into Kubernetes `Deployment`, `Service`, `PersistentVolumeClaim`, and `IngressRoute` manifests.
2.  **Encrypt and Commit Secrets:** Use `kubeseal` to create `SealedSecret` manifests for your application secrets and commit them to Git.
3.  **Deploy via GitOps:** Commit the application manifests to your Git repo and let Flux deploy them.
4.  **Migrate Data:** Stop the service on the old Docker host, `rsync` the data to a node, and use `kubectl cp` to copy it into the new persistent volume.
5.  **Cutover:** Update your FritzBox port forwarding rules to point to the Traefik IP (`192.168.123.100`).
6.  **Decommission Old Service:** Remove the service from your `docker-compose.yml`.

### **Phase 4: Decommission the Old Docker Host**

1.  **Final Verification:** After all services are stable, perform a final check.
2.  **Shutdown & Wait:** Shut down the old Docker VM and wait a week to ensure nothing was missed.
3.  **Backup & Delete:** Create a final backup of the VM, then delete it from Proxmox.

---

## **3. Upgrades & Maintenance: The Talos Advantage**

Managing and upgrading a Talos cluster is radically simpler.

*   **OS and Kubernetes Upgrades:** To upgrade the entire cluster (both the Talos OS and the Kubernetes version) to a new version, you run a single command. Talos handles the safe, rolling update process automatically.
    ```bash
    # Example: Upgrade the entire cluster to a new version
    talosctl upgrade --to factory.talos.dev/installer/v1.7.1
    ```
*   **Node Configuration Changes:** To change a node's configuration (e.g., add a new label), you edit its YAML file and apply it with `talosctl apply-config`. The node will reboot with the new configuration.

You have now built a highly secure, reproducible, and easy-to-manage Kubernetes homelab.

rene-kschamer_sap: Your using Linux Bridges for the networks. Promox also allows to setup VLANs directly. What would be the difference?

GitHub Copilot: Excellent question. This is a fundamental choice in Proxmox networking with significant implications. Let's break down the difference between the two approaches.

### **High-Level Analogy**

*   **Multiple Linux Bridges (Our Current Setup):** Think of this as building **separate, physical roads** inside your Proxmox host. Each bridge (`vmbr1`, `vmbr2`) is a completely separate road. The Proxmox host itself acts as the traffic controller, building small overpasses (`iptables` rules) to let traffic move between these roads and out to the main highway (the internet).

*   **VLAN-Aware Bridge:** Think of this as building **one single, multi-lane superhighway** (`vmbr0`). Each lane is marked with a number (a VLAN Tag, like 10, 20, 30). Cars (network packets) are "tagged" to stay in their lane. To get traffic from one lane to another or onto the main highway, you need a sophisticated interchange system: **a managed network switch**.

---

### **Comparison Table**

| Feature | **Multiple Linux Bridges (Software VLANs)** | **VLAN-Aware Bridge (Hardware VLANs)** |
| :--- | :--- | :--- |
| **Hardware Requirement** | **None.** Works with any switch, including your FritzBox. | **Managed Switch Required.** Your switch must support 802.1q VLAN tagging. |
| **Proxmox Config** | Longer `/etc/network/interfaces` file. One stanza per network. | Shorter `/etc/network/interfaces` file. One main bridge. |
| **VM Configuration** | Assign VM to a specific bridge (e.g., `vmbr2`). | Assign VM to the main bridge (`vmbr0`) and add a **VLAN Tag** (e.g., `30`). |
| **Isolation Method** | **Software-based.** Proxmox kernel and `iptables` enforce isolation. | **Hardware-based.** The managed switch enforces isolation between VLANs. |
| **Inter-VLAN Routing** | Handled by the **Proxmox host's CPU**. | Handled by the **managed switch or a dedicated router/firewall**. |
| **Performance** | Minor CPU overhead on the Proxmox host for routing traffic between networks. | Higher performance, as routing is offloaded to dedicated network hardware. |
| **Scalability** | Good for a single host. Becomes complex if you add more physical hosts. | **Excellent.** The standard for multi-host setups and professional environments. |
| **Best For** | **Single-host homelabs** without a managed switch. **This is your current situation.** | Multi-host clusters, enterprise environments, or homelabs with prosumer/enterprise networking gear. |

---

### **Method 1: Multiple Linux Bridges (What we are using)**

This is a self-contained solution entirely within the Proxmox host.

**How it Works:**
*   Each `vmbrX` is a separate virtual switch.
*   They are not connected to each other by default.
*   The `post-up iptables ... MASQUERADE` rules you see in the configuration tell the Proxmox host to act as a router, performing Network Address Translation (NAT) for any VM on that bridge trying to reach the outside world via `vmbr0`.

**Configuration Snippet (`/etc/network/interfaces`):**
```bash
# DMZ bridge (isolated)
auto vmbr2
iface vmbr2 inet static
    address 10.10.30.1/24
    bridge-ports none # Not connected to any physical port
    ...
    post-up iptables -t nat -A POSTROUTING -s '10.10.30.0/24' -o vmbr0 -j MASQUERADE
```

**Pros:**
*   **No extra cost or hardware.** It works perfectly with the unmanaged switch built into your FritzBox.
*   Simple to conceptualize for a single server.

**Cons:**
*   All inter-network traffic (e.g., a trusted pod fetching data from a DMZ pod) must be processed by the Proxmox host's CPU.
*   Less "clean" from a networking purist's perspective.

---

### **Method 2: VLAN-Aware Bridge (The Alternative)**

This method integrates Proxmox into a larger, VLAN-capable network fabric.

**How it Works:**
*   There is only one main bridge (`vmbr0`) connected to your physical network.
*   This bridge is configured with `bridge-vlan-aware yes`.
*   When you assign a VM to `vmbr0` with VLAN Tag `30`, Proxmox wraps all of that VM's network traffic in a "VLAN 30" digital envelope before sending it out.
*   Your managed switch receives this traffic, reads the tag, and ensures it only goes to other ports configured for VLAN 30.

**Configuration Snippet (`/etc/network/interfaces`):**
```bash
# A single, VLAN-aware bridge
auto vmbr0
iface vmbr0 inet static
    address 192.168.123.2/24
    gateway 192.168.123.1
    bridge-ports enp0s31f6
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes # This is the magic setting
    bridge-vids 2-4094    # Tells the bridge which VLANs to be aware of
```
**VM Configuration in Proxmox GUI:**
You would select `vmbr0` for the network device and then type `30` into the "VLAN Tag" field.

**Pros:**
*   **Higher Performance:** Offloads routing from the Proxmox CPU to dedicated network hardware.
*   **More Scalable:** You can have multiple Proxmox hosts connected to the same switch, and VMs on different hosts can be on the same VLAN seamlessly.
*   The "professional" way to do network segmentation.

**Cons:**
*   **Requires a managed switch.** A standard FritzBox cannot do this. You would need to buy a switch from a brand like Ubiquiti, TP-Link Omada, Mikrotik, etc.

### **Conclusion & Recommendation for You**

The **Multiple Linux Bridges** approach I have outlined is the **correct and best choice for your current hardware setup.** Your FritzBox is a router with a simple, unmanaged switch. It does not understand VLAN tags.

The software-defined method gives you all the security and isolation benefits of VLANs without needing to buy a new, more expensive managed switch. It is the perfect solution for a powerful single-server homelab like yours.
