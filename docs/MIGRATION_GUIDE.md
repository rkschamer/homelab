# Step-by-Step Migration Guide

This guide outlines a gradual transition from a single Docker host to the new Kubernetes cluster with minimal downtime.

## Phase 0: Preparation & Backup (No Downtime)

1. **Backup Everything:** Create a full backup of all existing Docker volumes and configuration files.
2. **Document Services:** List all running services, their data paths, ports, and environment variables.
3. **Set Up Git:** Create this repository on GitHub to serve as the single source of truth.
4. **Install Tools:** On your local machine, install `kubectl`, `cilium-cli`, `flux`, and `kubeseal`.

## Phase 1: Build the Foundation (No Downtime)

*Goal: Build the new Kubernetes platform while the old Docker host continues to run all services.*

1. **Configure Proxmox Networking:** Create the Linux bridges (`vmbr0`, `vmbr1`, `vmbr2`, `vmbr3`, `vmbr4`) on the Proxmox host.

2. **Create VMs:** Create the virtual machines for the control plane and worker nodes.

3. **Generate Talos Configuration:** Use `talosctl gen config` to generate the machine configurations for your control plane and worker nodes.
   - Talos files are kept in this repository, but are encrypted with git-crypt

4. **Install Talos Cluster:** Boot the VMs with the generated configurations to form the cluster.

5. **Bootstrap the Cluster:** From your local machine, install the core components via Helm:
   - **Cilium + Hubble** (in eBPF mode, kube-proxy replacement)
   - **MetalLB** (Layer 2 mode)
   - **Sealed Secrets Controller**
   - **Flux CD** (pointing to this repository) - *will manage all application deployments going forward*

### 5.1 Install Cilium and Hubble

Cilium is the CNI (Container Network Interface) that replaces kube-proxy and provides advanced networking and security policies.

**Prerequisites:**
- `helm` CLI installed locally
- `kubectl` configured to access your cluster
- `cilium-cli` installed (optional but recommended for verification)

**Install Cilium with Hubble:**

```bash
# Add Cilium Helm repository
helm repo add cilium https://helm.cilium.io
helm repo update

# Create cilium namespace
kubectl create namespace cilium

# Install Cilium with eBPF mode and Hubble
helm install cilium cilium/cilium \
  --namespace cilium \
  --set kubeProxyReplacement=true \
  --set ebpf.enabled=true \
  --set hubble.enabled=true \
  --set hubble.metrics.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set l7Proxy=true \
  --set policyEnforcementMode=default \
  --set routingMode=native \
  --set endpointRoutes.enabled=true \
  --wait
```

**Key configuration options:**
- `kubeProxyReplacement=true`: Cilium replaces kube-proxy for service load balancing
- `ebpf.enabled=true`: Use eBPF for efficient networking and packet processing
- `hubble.enabled=true`: Enable Hubble for network visibility and observability
- `hubble.ui.enabled=true`: Deploy Hubble UI for visual network debugging
- `policyEnforcementMode=default`: Enforce CiliumNetworkPolicy by default (deny unless explicitly allowed)
- `l7Proxy=true`: Enable Layer 7 (application-level) visibility for debugging

**Verify Installation:**

```bash
# Check Cilium pods are running
kubectl get pods -n cilium

# Verify Cilium agent status
kubectl exec -n cilium -t ds/cilium -- cilium status

# Check that kube-proxy is not running
kubectl get daemonset -n kube-system kube-proxy

# Port-forward to Hubble UI (optional)
kubectl port-forward -n cilium svc/hubble-ui 8081:80
# Then visit http://localhost:8081 in your browser
```

**Next Steps:**
After Cilium is running, proceed to install MetalLB and other core components. Network policies can be defined later as applications are deployed.

For detailed installation instructions, troubleshooting, and network policy examples, see [CILIUM_HUBBLE_SETUP.md](CILIUM_HUBBLE_SETUP.md).

## Phase 2: Deploy Core Services via GitOps (No Downtime)

*Goal: Use Flux to deploy platform services to the new cluster.*

1. **Deploy MetalLB:** Configure MetalLB to run on the control plane in **Layer 2 mode** with an IP pool from `192.168.123.21-29`. The control plane's MetalLB speaker will advertise these IPs to the FritzBox network.

2. **Deploy Traefik:** Add the `HelmRelease` for Traefik to this repository. Configure it to run on the DMZ worker nodes and use a LoadBalancer service to get an IP from the MetalLB pool.
   - Traefik will receive an IP from `192.168.123.21-29` (via the control plane speaker)
   - External traffic reaches Traefik through the management network (192.168.123.x)
   - Traefik can route to internal services on 192.168.123.0/24 and forward to pods on Kubernetes networks

3. **Deploy Monitoring:** Add the `kube-prometheus-stack` Helm chart to this repository.

4. **Prepare for Cutover:** Before changing your main router settings, use a test domain or edit your local `/etc/hosts` file to point your service domains to the new Traefik IP (from the `192.168.123.21-29` pool) for verification.

## Phase 3: Migrate Applications One by One (Minimal Downtime per Service)

*Goal: Move each service from Docker to Kubernetes individually.*

For each application:

1. **Convert & Adapt Manifests:**
   - Use `kompose convert` to get baseline Kubernetes manifests from your `docker-compose.yml`.
   - Adapt these manifests: add `nodeSelector` for correct zone placement, create an `IngressRoute` for Traefik, and define a `PersistentVolumeClaim` for data.
   - Encrypt any secrets using `kubeseal` and commit the resulting `SealedSecret` manifest.

2. **Deploy to Kubernetes:** Commit the new manifests to this repository and let Flux deploy the application.

3. **Migrate Data (Downtime for this service begins):**
   - Stop the service on the old Docker host.
   - Copy the data from the Docker volume into the new Kubernetes persistent volume using `kubectl cp`.

4. **Test & Cutover:**
   - Verify the service is running correctly in Kubernetes.
   - **This is the cutover point.** Update your FritzBox port forwarding rules to point to the MetalLB IP from the pool (`192.168.123.21-29`).
   - Confirm the service is accessible from the internet.

5. **Decommission Old Service:** Remove the service from your old `docker-compose.yml`.

## Phase 4: Decommission the Old Docker Host

1. **Final Verification:** After all services are migrated and stable, perform a final check.

2. **Shutdown & Wait:** Shut down the old Docker VM. Keep it offline for a week as a "cooling-off" period.

3. **Final Backup & Deletion:** Create a final backup of the shutdown VM, then delete it from Proxmox to reclaim resources.

---

## Best Practices During Migration

- **Test Before Committing:** Always test new Kubernetes manifests in a development environment first
- **Use Feature Flags:** For services that support it, use feature flags to route a percentage of traffic to the new version
- **Monitor Both Systems:** Keep monitoring dashboards running for both the old Docker host and the new cluster during migration
- **Rollback Plan:** Have a clear rollback procedure for each migrated service in case issues arise
- **Communication:** Notify users of any service maintenance windows
- **Gradual Cutover:** For critical services, consider a gradual traffic shift rather than a hard cutover
