# Kubernetes Homelab on Proxmox

This repository contains the entire configuration for a secure, GitOps-driven Kubernetes homelab running on Proxmox VE. It is managed declaratively using Flux CD, with a strong emphasis on network segmentation and security best practices.

## Stack

- **Hypervisor:** Proxmox VE
- **Kubernetes:** Talos (lightweight, immutable OS)
- **Networking (CNI):** Cilium with eBPF + Hubble for observability
- **GitOps:** Flux CD
- **Ingress:** Traefik with ACME/Let's Encrypt
- **Load Balancing:** MetalLB
- **Secrets Management:** Sealed Secrets (with the master key stored externally in Vaultwarden)

## ⚠️ Note ⚠️

This repository is specifically designed for my homelab setup and is not intended for direct reuse in other environments. It contains encrypted secrets (protected via git-crypt) that are required for cluster access and cannot be used by others.

However, you can use this repository as a reference for building your own setup.

## Decrypt Configs

Some configurations contain secrets (e.g., `terraform.tfvars`, kubeconfig files) and for convenience are kept in the repository but encrypted with **git-crypt**. You need to initialize and unlock git-crypt before you can access these files.

If you have the encryption key (stored in Vaultwarden or your password manager):

```bash
# Place the key file in a secure location
# Then unlock the repository
git-crypt unlock /path/to/encryption-key
```

**🛑 Remember to add all secrets that you need to protect to `.gitattributes` before committing!**

### Important Security Notes

- **Never commit the encryption key to Git.** Store it securely in Vaultwarden or offline.
- **Only authorized users should have the key.** Each person needing access must obtain it separately.
- **Encrypted files in Git are binary.** They cannot be viewed without the key, even in the Git history.
- **Sealed Secrets private keys are NOT managed by git-crypt.** Export and store them separately (see Sealed Secrets backup procedure in [Talos Installation](docs/talos-installation.md#backup-the-sealed-secrets-private-key)).

## Architecture Overview

```
                              Internet
                                 │
                                 ▼
                    ┌─────────────────────────┐
                    │  FritzBox Router        │
                    │  192.168.123.1          │
                    │  (Port Fwd 80/443 to    │
                    │   192.168.123.21-29)    │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  Proxmox VE Host        │
                    │  192.168.123.8          │
                    └────────────┬────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
    ┌───▼──────────┐       ┌─────▼──────────────┐  ┌──────▼─────────┐
    │vmbr0         │       │     vmbr1          │  │   Kubernetes   │
    │Mgmt          │       │   Workers          │  │    Cluster     │
    │192.168.123.x │       │  10.10.20.0/24     │  │     (Talos)    │
    └───┬──────────┘       └─────┬──────────────┘  └────────┬───────┘
        │                        │                          │
    ┌───▼────────────────────────▼──────────────────────────▼────────┐
    │            Control Plane (192.168.123.20)                      │
    │  ┌──────────────────────────────────────────────────────────┐  │
    │  │ Bastion & Router | IP Forwarding: ENABLED                │  │
    │  │ ens18: 192.168.123.20/24 (mgmt)                          │  │
    │  │ ens19: 10.10.20.2/24 (workload network)                  │  │
    │  │                                                          │  │
    │  │ Services: Flux CD, Sealed Secrets, MetalLB Speaker       │  │
    │  │ MetalLB Pool: 192.168.123.21-29 (for LoadBalancer)       │  │
    │  └──────────────────────────────────────────────────────────┘  │
    └──┬───────────────────────────────────────────────────────────┘
       │
    10.10.20.0/24 (Workload Network)
       │
    ┌──▼──────────┐ ┌──▼──────────┐
    │ Worker-1   │ │ Worker-2   │
    │ Pods with  │ │ Pods with  │
    │ zone labels│ │ zone labels│
    │ (trusted,  │ │ (dmz,      │
    │ dmz, etc)  │ │ untrusted) │
    └────────────┘ └────────────┘
```

## Network Setup

The cluster uses two physical networks: **Management (vmbr0)** for the control plane and **Workload (vmbr1)** for all worker nodes. Network zone isolation (Trusted, DMZ, Untrusted, Monitoring) is enforced at the **pod level using Cilium Network Policies** based on namespace labels. See the [Network Architecture](docs/NETWORK_ARCHITECTURE.md) documentation for detailed overview.

- **Management (192.168.123.0/24)**  - Control plane, admin access, and MetalLB pool
- **Workload   (10.10.20.0/24)**     - All worker nodes; pods labeled by zone (trusted, dmz, untrusted, monitoring)

**Network Isolation:**
- Physical isolation reduces to 2 networks, eliminating per-zone VM overhead
- Logical network zones (Trusted, DMZ, Untrusted, Monitoring) are enforced via namespace labels: `network-zone: [trusted|dmz|untrusted|monitoring]`
- Cilium Network Policies enforce default-deny and explicit inter-zone communication rules at the pod level
- Host firewall rules provide an additional security layer (optional)

## Setting up the Cluster

### 1. Infrastructure Setup via Terraform and Talos Linux

This Terraform configuration deploys a Talos Kubernetes cluster on Proxmox VE using an ISO-based approach. The Talos Terraform provider generates the base configuration, which is then combined with manually written manifest files that adapt the configuration to your specific network setup.

---

### 🔗 [Terraform & Infrastructure Setup](terraform/README.md)

**Overview:** Comprehensive guide for provisioning the entire Kubernetes cluster on Proxmox using Terraform. Covers infrastructure as code, VM creation, and Talos configuration generation.

**Key Topics:**
- ISO-based Talos deployment approach
- Terraform project structure and prerequisites
- VM provisioning for control plane and workers
- Talos machine configuration generation
- Network attachment strategy for isolation
- Best practices for Proxmox automation

**When to read:** Before running `terraform apply`, or when modifying the infrastructure configuration.

---

### 🔗 [Bootstrap Guide](docs/BOOTSTRAP_GUIDE.md)

**Overview:** Step-by-step walkthrough for bootstrapping the Talos cluster, applying configurations to nodes, and verifying cluster readiness. Includes bastion configuration and troubleshooting.

**Key Topics:**
- Prerequisites and pre-flight checks
- Control plane bootstrap process
- Worker node configuration via bastion host
- Static IP assignment on isolated networks
- Talos configuration application
- Cluster verification and health checks
- Post-bootstrap networking understanding

**When to read:** After Terraform creates VMs, before applying Talos configurations.

---

### 🔗 [Cilium and Hubble Installation](docs/CILIUM_HUBBLE_SETUP.md)

**Overview:** Detailed installation and configuration of Cilium CNI and Hubble network observability. Covers advanced networking features, network policies, and observability tools.

**Key Topics:**
- Cilium installation with eBPF mode
- Hubble deployment for network visibility
- kube-proxy replacement strategy
- Network policy implementation
- Hubble UI and network debugging
- DNS visibility and service load balancing
- Optional WireGuard encryption setup

**When to read:** After cluster bootstrap is complete, before deploying applications.

---

### 📋 [Setup Checklist](SETUP_CHECKLIST.md)

**Overview:** Comprehensive checklist covering all prerequisites and configuration items needed before and during the cluster setup. Use this to verify nothing is missed.

**Sections:**
- Proxmox configuration prerequisites
- Local admin machine tool installation
- Git repository structure requirements
- Terraform configuration validation
- Talos configuration verification
- Pre-bootstrap checklist

**When to read:** At the beginning of your setup journey to ensure all prerequisites are met.

---

### 🔗 [Migration Guide](docs/MIGRATION_GUIDE.md)

**Overview:** Detailed plan for gradually migrating services from Docker to Kubernetes with minimal downtime. Covers phased approach from preparation through decommissioning the old platform.

**Key Topics:**
- Phase 0: Backup and preparation
- Phase 1: Build Kubernetes foundation while running Docker
- Phase 2: Deploy core services via GitOps
- Phase 3: Migrate applications one by one
- Phase 4: Decommission the old Docker host
- Best practices during migration

**When to read:** When planning your service migration to the new cluster.

---

### 🔗 [Cluster Upgrades and Maintenance](docs/CLUSTER_UPGRADES.md)

**Overview:** Operational procedures for upgrading Talos nodes, Kubernetes, Cilium, and other components with zero downtime. Covers rolling updates, rollback procedures, and automated upgrades.

**Key Topics:**
- OS (Talos) upgrade procedure
- Kubernetes version upgrades
- CNI (Cilium) upgrades
- Automated upgrades with System Upgrade Controller
- Rollback procedures
- Pre/post-upgrade checklists
- Troubleshooting upgrade failures

**When to read:** Before performing any cluster upgrades or maintenance.

---

## Quick Start Summary

1. **Prepare Infrastructure:** Follow [Network Architecture](docs/NETWORK_ARCHITECTURE.md) to understand the network design. Use [Setup Checklist](SETUP_CHECKLIST.md) to verify all prerequisites.

2. **Provision Cluster:** Use [Terraform & Infrastructure Setup](terraform/README.md) to provision all VMs and generate Talos configurations.

3. **Bootstrap Cluster:** Follow [Bootstrap Guide](docs/BOOTSTRAP_GUIDE.md) to apply Talos configs and form the Kubernetes cluster.

4. **Install CNI:** Use [Cilium and Hubble Installation](docs/CILIUM_HUBBLE_SETUP.md) to deploy the network layer and observability tools.

5. **Migrate Applications:** Follow [Migration Guide](docs/MIGRATION_GUIDE.md) to move services from Docker to Kubernetes with zero downtime.

6. **Maintain Cluster:** Refer to [Cluster Upgrades and Maintenance](docs/CLUSTER_UPGRADES.md) for upgrade procedures and operational tasks.

---

## GitOps Principles

All configurations in this repository follow GitOps best practices:

- **Git is the Source of Truth:** All cluster state is defined declaratively in YAML files
- **Flux CD for Automation:** Changes committed to Git are automatically synchronized to the cluster
- **Infrastructure as Code:** Proxmox resources provisioned via Terraform, committed to Git
- **Secrets Management:** All secrets encrypted as SealedSecrets before committing
- **Network Policies:** Pod-level isolation defined as CiliumNetworkPolicy resources
- **No Manual Changes:** Avoid `kubectl apply` for permanent changes; use Git commits instead

---

## Repository Structure

```
.
├── README.md                          # This file - project overview and navigation
├── SETUP_CHECKLIST.md                # Pre-flight checklist
├── LICENSE                           # Project license
├── docs/
│   ├── BOOTSTRAP_GUIDE.md            # Step-by-step cluster bootstrap
│   ├── NETWORK_ARCHITECTURE.md       # Network design and topology
│   ├── CILIUM_HUBBLE_SETUP.md        # CNI and observability installation
│   ├── MIGRATION_GUIDE.md            # Docker to Kubernetes migration plan
│   └── CLUSTER_UPGRADES.md           # Upgrade and maintenance procedures
├── terraform/
│   ├── *.tf                          # Terraform manifests
│   ├── terraform.tfvars              # Configuration (contains secrets)
│   ├── terraform.tfstate             # State file (contains sensitive data)
│   ├── patches/
│   │   └── install-disk-and-hostname.yaml.tpl
│   └── README.md                     # Detailed Terraform documentation
├── talos/
│   ├── gen/                          # Generated Talos configs and kubeconfig
│   ├── manifests/                    # LinkConfig manifests for workers
│   └── bootstrap/
├── flux/
│   ├── flux-system/                  # Flux system components
│   ├── infrastructure/               # Core platform services (MetalLB, Traefik, etc.)
│   └── apps/                         # User-facing applications
└── secrets/                          # Encrypted SealedSecrets (created after bootstrap)
```
