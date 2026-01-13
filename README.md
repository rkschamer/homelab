# Kubernetes Homelab on Proxmox

This repository contains the entire configuration for a secure, GitOps-driven Kubernetes homelab running on Proxmox VE. It is managed declaratively using Flux CD, with a strong emphasis on network segmentation and security best practices.

## 1. Architecture Overview

The entire platform is designed to be resilient, secure, and fully automated. All configurations, from infrastructure to applications, are managed as code in this Git repository.

*   **Hypervisor:** Proxmox VE
*   **Kubernetes:** Talos
*   **Networking (CNI):** Cilium with eBPF + Hubble for observability
*   **GitOps:** Flux CD
*   **Ingress:** Traefik
*   **Load Balancing:** MetalLB
*   **Secrets Management:** Sealed Secrets (with the master key stored externally in Vaultwarden)
*   **TLS:** Traefik's built-in ACME client

### Architecture Diagram

```
                                                                                             +-----------------+
                                                                                             |   Vaultwarden   |
                                                                                             | (Stores Master  |
                                                                                             |   Sealed Key)   |
                                                                                             +-------+---------+
                                                                                                     ^
                                                                                                     | (Manual)
                                                                                                     |
+------------------+      +------------------+                                               +-------+---------+
|  Admin's Laptop  |----->|   GitHub Repo    |                                               |  kubeseal CLI   |
| (kubectl, flux)  |      | (homelab-k8s)    |                                               | (Encrypts Secret|
+------------------+      +--------+---------+                                               +-----------------+
                                   |                                                                 ^
                                   | (1. Git Push)                                                   |
                                   |                                                                 |
                                   v                                                                 |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|                                          Internet                                                  |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
                                                 |
                                                 v
+----------------------------------------------------------------------------------------------------+
|                                FritzBox Router (192.168.123.1)                                     |
|                           (Port Forwards 80/443 to 192.168.123.21-29)                              |
+----------------------------------------------------------------------------------------------------+
                                                 |
                                                 v
+----------------------------------------------------------------------------------------------------+
|                                    Proxmox VE Hypervisor Host                                      |
|                                                                                                    |
|  +-----------------------------------------------------------------------------------------------+ |
|  |                                  Kubernetes Cluster (Talos)                                     | |
|  |                                                                                               | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |  | Cilium CNI + Hubble + WireGuard (Network Fabric & Pod-to-Pod Encryption)                 | | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |                                                                                               | |
|  |  +-----------------+   +-----------------+   +-----------------+   +------------------------+ | |
|  |  | Control Plane   |   | DMZ Worker VM   |   | Trusted Worker VM |   | Untrusted Worker VM    | | |
|  |  | VM              |   | (Public Facing) |   | (Internal Apps)   |   | (Experiments)        | | |
|  |  |-----------------|   |-----------------|   |-----------------|   |------------------------| | |
|  |  | [FluxCD] <------(2. Syncs)------------|   | [Home Assistant]|   | [Temporary Test Pod]   | | |
|  |  | [Sealed Secrets |   | [Traefik Ingress] |   | [Plex]          |   |                        | | |
|  |  |  Controller]    |   | [Public App]    |   | [Database]      |   |                        | | |
|  |  | [MetalLB Speaker] |   | [Monitoring]    |   |                 |   |                        | | |
|  |  | (Layer 2 Mode)  |   |                 |   |                 |   |                        | | |
|  |  +-----------------+           | (4. Routes Traffic) | (Cilium Policy Allows)   | (Isolated)  | |
|  |                                |<--------------------|--------------------------|-------------| |
|  |                                v                     |                                        | |
|  |  +--------------------------------------------------+---------------------------------------+ | |
|  |  | MetalLB Pool: 192.168.123.21-29 (Advertised by Control Plane Speaker) <---(3. Routes to Traefik on DMZ)| | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |                                                                                               | |
|  +-----------------------------------------------------------------------------------------------+ |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

---

## Network Setup

We will create five distinct, isolated networks using **Linux Bridges** on the Proxmox host. This approach acts as a "software VLAN" setup and does not require a managed switch:

- `vmbr0`: **Management Network** (192.168.123.0/24) - Connects to your FritzBox LAN. Used for Proxmox management, Kubernetes API access, and MetalLB speaker.
    - `192.168.123.1`: FritzBox Router (gateway)
    - `192.168.123.8`: Proxmox Node (host)
    - `192.168.123.20`: Kubernetes Control Plane VM (Talos) - **Runs MetalLB speaker in Layer 2 mode**
    - `192.168.123.21-29`: MetalLB IP pool for LoadBalancer services (e.g., Traefik ingress) - **Advertised by control plane speaker**

- `vmbr1`: **Trusted Network** (10.10.20.0/24) - For internal services like Home Assistant. Can initiate traffic to the home LAN.
    - `10.10.20.1`: Gateway (Proxmox host acting as router)
    - `10.10.20.10`: Trusted Worker Node (Talos)

- `vmbr2`: **DMZ Network** (10.10.30.0/24) - For public-facing services like the Traefik ingress. Isolated from the home LAN.
    - `10.10.30.1`: Gateway (Proxmox host acting as router)
    - `10.10.30.10`: DMZ Worker Node (Talos)

- `vmbr3`: **Untrusted Network** (10.10.40.0/24) - For experiments. Completely isolated with internet-only egress.
    - `10.10.40.1`: Gateway (Proxmox host acting as router)
    - `10.10.40.10`: Untrusted Worker Node (Talos)

- `vmbr4`: **Monitoring Network** (10.10.50.0/24) - For monitoring services. Can initiate traffic to all other networks, but no inbound traffic is allowed, except for Grafana access.
    - `10.10.50.1`: Gateway (Proxmox host acting as router)
    - `10.10.50.10`: Monitoring Worker Node (Talos)

**Network Routing:** The Proxmox host acts as a router between all networks and provides internet access via NAT. Worker nodes in isolated networks can reach the control plane in the management network through static routes.

Network configuration done in `/etc/network/interfaces` on Proxmox node. Configuration available [`proxmox/host/network-interfaces`](proxmox/host/network-interfaces).

## Cluster Setup

The cluster is provisioned entirely using **Terraform** with the official **Talos** and **Proxmox** providers. This approach eliminates manual VM creation steps and generates all necessary Talos configurations automatically.

### Prerequisites

1.  **Terraform:** Ensure Terraform is installed on your machine.
2.  **Talos Tools:** Install `talosctl` and `talhelper` for cluster management.
3.  **Proxmox API Access:** Ensure you have API credentials configured with appropriate permissions.
4.  **Talos ISO:** Download the Talos installer ISO and upload it to your Proxmox storage.

### Setup Process

#### 1. Configure Terraform Variables

Create or edit [`proxmox/terraform/terraform.tfvars`](proxmox/terraform/terraform.tfvars) with your environment-specific values:

```hcl
proxmox_api_url           = "https://<PROXMOX_IP>:8006/api2/json"
proxmox_api_token_id      = "<TOKEN_ID>"
proxmox_api_token_secret  = "<TOKEN_SECRET>"
proxmox_node              = "pve"
cluster_name              = "homelab"
control_plane_ip          = "192.168.123.20"
control_plane_vmid        = 100

worker_nodes = [
  {
    name            = "talos-worker-dmz-1"
    vmid            = 101
    network_bridge  = "vmbr2"
    network_zone    = "dmz"
    cores           = 2
    memory          = 2048
    disk_size_gb    = 32
  },
  {
    name            = "talos-worker-trusted-1"
    vmid            = 102
    network_bridge  = "vmbr1"
    network_zone    = "trusted"
    cores           = 2
    memory          = 2048
    disk_size_gb    = 32
  },
  # ... additional worker nodes
]
```

#### 2. Initialize and Apply Terraform

From the [`proxmox/terraform/`](proxmox/terraform/) directory:

```bash
# Initialize Terraform
terraform init

# Review planned infrastructure
terraform plan

# Provision all VMs and generate Talos configurations
terraform apply
```

Terraform will:
- Download the Talos ISO to Proxmox storage
- Create the control plane VM and all worker nodes
- Generate Talos machine configurations for all nodes (saved in `proxmox/terraform/talos/`)
- Create the `talosconfig` file for cluster access

#### 3. Apply Talos Configuration to Nodes

Once the VMs are created and booted:

```bash
# Apply control plane configuration (from the terraform directory)
talosctl apply-config --insecure --nodes 192.168.123.20 --file ./talos/controlplane.yaml

# Apply worker node configurations
talosctl apply-config --insecure --nodes 192.168.123.21 --file ./talos/worker-talos-worker-dmz-1.yaml
talosctl apply-config --insecure --nodes 192.168.123.22 --file ./talos/worker-talos-worker-trusted-1.yaml
# ... repeat for additional workers
```

The nodes will install Talos and reboot automatically.

#### 4. Verify Cluster Readiness

```bash
# Export the generated talosconfig
export TALOSCONFIG=./proxmox/terraform/talos/talosconfig

# Wait for the control plane to be ready
talosctl health

# Retrieve kubeconfig
talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config

# Verify cluster connectivity
kubectl get nodes
```

Your Talos Kubernetes cluster is now ready for bootstrap with Flux and core platform components.

## 2. Step-by-Step Migration Plan

This plan outlines a gradual transition from a single Docker host to the new Kubernetes cluster with minimal downtime.

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Create a full backup of all existing Docker volumes and configuration files.
2.  **Document Services:** List all running services, their data paths, ports, and environment variables.
3.  **Set Up Git:** Create this repository on GitHub to serve as the single source of truth.
4.  **Install Tools:** On your local machine, install `kubectl`, `cilium-cli`, `flux`, and `kubeseal`.

### **Phase 1: Build the Foundation (No Downtime)**

*Goal: Build the new Kubernetes platform while the old Docker host continues to run all services.*

1.  **Configure Proxmox Networking:** Create the Linux bridges (`vmbr0`, `vmbr1`, `vmbr2`, `vmbr3`, `vmbr4`) on the Proxmox host.
2.  **Create VMs:** Create the virtual machines for the control plane and worker nodes.
3.  **Generate Talos Configuration:** Use `talosctl gen config` to generate the machine configurations for your control plane and worker nodes.
  - Talos files are kept in this repository, but are encrypted with git-crypt
4.  **Install Talos Cluster:** Boot the VMs with the generated configurations to form the cluster.
5.  **Bootstrap the Cluster:** From your local machine, install the core components via Helm and Flux:
    *   **Cilium + Hubble** (in kube-proxy replacement mode)
    *   **MetalLB**
    *   **Sealed Secrets Controller**
    *   **Flux CD** (pointing to this repository)

### **Phase 2: Deploy Core Services via GitOps (No Downtime)**

*Goal: Use Flux to deploy platform services to the new cluster.*

1.  **Deploy MetalLB:** Configure MetalLB to run on the control plane in **Layer 2 mode** with an IP pool from `192.168.123.21-29`. The control plane's MetalLB speaker will advertise these IPs to the FritzBox network.
2.  **Deploy Traefik:** Add the `HelmRelease` for Traefik to this repository. Configure it to run on the DMZ worker nodes and use a LoadBalancer service to get an IP from the MetalLB pool.
   - Traefik will receive an IP from `192.168.123.21-29` (via the control plane speaker)
   - External traffic reaches Traefik through the management network (192.168.123.x)
   - Traefik can route to internal services on 192.168.123.0/24 and forward to pods on Kubernetes networks
3.  **Deploy Monitoring:** Add the `kube-prometheus-stack` Helm chart to this repository.
4.  **Prepare for Cutover:** Before changing your main router settings, use a test domain or edit your local `/etc/hosts` file to point your service domains to the new Traefik IP (from the `192.168.123.21-29` pool) for verification.

### **Phase 3: Migrate Applications One by One (Minimal Downtime per Service)**

*Goal: Move each service from Docker to Kubernetes individually.*

For each application:

1.  **Convert & Adapt Manifests:**
    *   Use `kompose convert` to get baseline Kubernetes manifests from your `docker-compose.yml`.
    *   Adapt these manifests: add `nodeSelector` for correct zone placement, create an `IngressRoute` for Traefik, and define a `PersistentVolumeClaim` for data.
    *   Encrypt any secrets using `kubeseal` and commit the resulting `SealedSecret` manifest.
2.  **Deploy to Kubernetes:** Commit the new manifests to this repository and let Flux deploy the application.
3.  **Migrate Data (Downtime for this service begins):**
    *   Stop the service on the old Docker host.
    *   Copy the data from the Docker volume into the new Kubernetes persistent volume using `kubectl cp`.
4.  **Test & Cutover:**
    *   Verify the service is running correctly in Kubernetes.
    *   **This is the cutover point.** Update your FritzBox port forwarding rules to point to the MetalLB IP from the pool (`192.168.123.21-29`).
    *   Confirm the service is accessible from the internet.
5.  **Decommission Old Service:** Remove the service from your old `docker-compose.yml`.

### **Phase 4: Decommission the Old Docker Host**

1.  **Final Verification:** After all services are migrated and stable, perform a final check.
2.  **Shutdown & Wait:** Shut down the old Docker VM. Keep it offline for a week as a "cooling-off" period.
3.  **Final Backup & Deletion:** Create a final backup of the shutdown VM, then delete it from Proxmox to reclaim resources.

---

## 3. Cluster Upgrades

Upgrades must be performed carefully to ensure high availability.

*   **Backup First:** Always take a Proxmox snapshot of all cluster VMs before starting an upgrade.
*   **Rolling Updates:** Upgrade one node at a time.
*   **OS Upgrades:** Cordon and drain each **worker node first**, perform the `apt upgrade`, reboot, and uncordon. The **control plane node is last**.
*   **k3s Upgrades:** Upgrade the **control plane node first**, then cordon, drain, and upgrade each **worker node** one by one.
*   **Automation:** For a true GitOps approach, use the **System Upgrade Controller** and define `Plan` manifests in this repository to automate the rolling upgrade process.
