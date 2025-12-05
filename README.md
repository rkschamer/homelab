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
|                           (Port Forwards 80/443 to 192.168.123.100)                                |
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
|  |  | [MetalLB]       |   | [Monitoring]    |   |                 |   |                        | | |
|  |  | [Monitoring]    |   +-------^---------+   +-------^---------+   +------------^-----------+ | |
|  |  +-----------------+           | (4. Routes Traffic) | (Cilium Policy Allows)   | (Isolated)  | |
|  |                                |<--------------------|--------------------------|-------------| |
|  |                                v                     |                                        | |
|  |  +--------------------------------------------------+---------------------------------------+ | |
|  |  | MetalLB Virtual IP: 192.168.123.100 (Handled by Traefik) <---(3. Forwards Traffic)--------| | |
|  |  +------------------------------------------------------------------------------------------+ | |
|  |                                                                                               | |
|  +-----------------------------------------------------------------------------------------------+ |
|                                                                                                    |
+----------------------------------------------------------------------------------------------------+
```

---

## Network Setup

We will create five distinct, isolated networks using **Linux Bridges** on the Proxmox host. This approach acts as a "software VLAN" setup and does not require a managed switch:

- `vmbr0`: **Management Network** (192.168.123.0/24) - Connects to your FritzBox LAN. Used for Proxmox management and Kubernetes API access.
    - `192.168.123.1`: FritzBox Router (gateway)
    - `192.168.123.8`: Proxmox Node (host)
    - `192.168.123.20`: Kubernetes Control Plane VM (Talos)
    - `192.168.123.21-29`: MetalLB IP pool for LoadBalancer services (e.g., Traefik ingress)

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

### Create VM Template

The used VM template is manually created, since it pretty complex to use Terraform for this. To do this, a VM needs to be created, booted from iso first, installs Talso and then change the boot priority to boot from disk the next time.
Instead the created VM template serves as "golden image", which is used to clone the actual nodes.

#### 1. Create Temporary VM

This VM also can be created using the Proxmox Web UI.

```bash
# 1. Create the VM with basic specs
#    We'll use vmbr0 for now; it doesn't matter much for the template itself.
qm create 9000 --name "talos-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0

# 2. Create a virtual disk for the OS installation
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-zfs:vm-9000-disk-0,iothread=1,size=32G,ssd=1

# 3. Attach the Talos installer ISO
qm set 9000 --ide2 local:iso/talos-metal-amd64.iso,media=cdrom

# 4. Set the VM to boot from the ISO first
qm set 9000 --boot order=ide2

# 5. Add serial console settings (recommended for Talos)
qm set 9000 --serial0 socket --vga serial0

# 6. Start VM
qm start 9000
```

#### 2. Install Talos

The installation process will run, and the VM will automatically reboot itself.

```bash
talosctl apply-config --insecure --nodes <VM_IP_ADDRESS> --file ./proxmox/homelab-cluster/talos/controlplane.yaml
```

#### 3. Finalize and Convert to Template

After the VM reboots, the installation is complete. Now, you'll clean it up and convert it into a read-only template.

```bash
# 1. Wait for the installation to finish and the VM to reboot, then shut it down.
qm shutdown 9000

# 2. Detach the installer ISO. It's no longer needed.
qm set 9000 --ide2 none

# 3. Change the boot order to boot from the main disk (scsi0) from now on.
qm set 9000 --boot order=scsi0

# 4. (Optional but Recommended) Reset cloud-init data, just in case.
#    This ensures clones get a clean slate.
qm set 9000 --cicustom ""

# 5. Convert the VM into a template. This makes it a read-only, clonable image.
qm template 9000
```

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

1.  **Deploy Traefik:** Add the `HelmRelease` for Traefik to this repository. Configure it to run on the DMZ node and use the MetalLB virtual IP.
2.  **Deploy Monitoring:** Add the `kube-prometheus-stack` Helm chart to this repository.
3.  **Prepare for Cutover:** Before changing your main router settings, use a test domain or edit your local `/etc/hosts` file to point your service domains to the new Traefik IP (`192.168.123.100`) for verification.

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
    *   **This is the cutover point.** Update your FritzBox port forwarding rules to point to the new Traefik IP (`192.168.123.21-29`).
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
