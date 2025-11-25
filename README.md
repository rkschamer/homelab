# Kubernetes Homelab on Proxmox

This repository contains the entire configuration for a secure, GitOps-driven Kubernetes homelab running on Proxmox VE. It is managed declaratively using Flux CD, with a strong emphasis on network segmentation and security best practices.

## 1. Architecture Overview

The entire platform is designed to be resilient, secure, and fully automated. All configurations, from infrastructure to applications, are managed as code in this Git repository.

*   **Hypervisor:** Proxmox VE
*   **Kubernetes:** k3s
*   **Networking (CNI):** Cilium with eBPF + Hubble for observability
*   **GitOps:** Flux CD
*   **Ingress:** Traefik
*   **Load Balancing:** MetalLB
*   **Secrets Management:** Sealed Secrets (with the master key stored externally in Vaultwarden)
*   **TLS:** traefik with Let's Encrypt

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
|  |                                  Kubernetes Cluster (k3s)                                     | |
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
|  |  | [cert-manager]  |   +-------^---------+   +-------^---------+   +------------^-----------+ | |
|  |  | [MetalLB]       |           |                     |                          |             | |
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

## 2. Step-by-Step Migration Plan

This plan outlines a gradual transition from a single Docker host to the new Kubernetes cluster with minimal downtime.

### **Phase 0: Preparation & Backup (No Downtime)**

1.  **Backup Everything:** Create a full backup of all existing Docker volumes and configuration files.
2.  **Document Services:** List all running services, their data paths, ports, and environment variables.
3.  **Set Up Git:** Create this repository on GitHub to serve as the single source of truth.
4.  **Install Tools:** On your local machine, install `kubectl`, `cilium-cli`, `flux`, and `kubeseal`.

### **Phase 1: Build the Foundation (No Downtime)**

*Goal: Build the new Kubernetes platform while the old Docker host continues to run all services.*

1.  **Configure Proxmox Networking:** Create the Linux bridges (`vmbr0`, `vmbr1`, `vmbr2`, `vmbr3`) on the Proxmox host.
2.  **Create VMs:** Create the Ubuntu cloud-init template and clone the four VMs (control plane, trusted, DMZ, untrusted).
3.  **Install k3s Cluster:** Install k3s on the control plane **without the default CNI** (`--flannel-backend=none`) and join the worker nodes.
4.  **Bootstrap the Cluster:** From your local machine, install the core components:
    *   **Cilium + Hubble**
    *   **MetalLB**
    *   **cert-manager**
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
    *   **This is the cutover point.** Update your FritzBox port forwarding rules to point to the new Traefik IP (`192.168.123.100`).
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
