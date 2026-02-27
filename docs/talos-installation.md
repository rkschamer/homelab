# Talos Installation

This guide walks through creating VMs on Proxmox and bootstrapping a Talos Kubernetes cluster on a single workload network, with pod-level network isolation enforced via Cilium Network Policies.

The cluster creation is a semi-automated process, since several step of the bootstrapping process is not supported by the Proxmox Terraform provider (yet?).

## Step 1: `terraform apply`

- Navigate to [`terraform/`](../terraform/) and run `terraform apply`.
- Proxmox will create VMs with SecureBoot enabled and cloud-init network configuration automatically.
- The control plane will boot and request DHCP on vmbr0, receiving **192.168.123.20** via static DHCP lease.
- Worker nodes will have network configuration applied via Proxmox cloud-init (no manual steps needed):
  - **Worker-1**: 10.10.20.21/24
  - **Worker-2**: 10.10.20.22/24
- The created VM will boot from the Talos ISO image, making them read to receive Talos cluster configuration

## Step 2: `talosctl apply-config`

- `terraform apply` also generated Talos configuration, which need to be applied to the created node VMs
- Navigate to `talos/gen`, which contains the generated Talos configuration for each node
- Apply the configuration:

  ```bash
  talosctl apply-config \
    --insecure \
    --nodes <node-ip> \
    --file ./talos/gen/<node-name>.yaml
  ```
- Wait 2-3 minutes for the control plane to install and reboot.
- **After reboot make sure that Talos is booting the from disk and not from the ISO again**
  - This can be done by entering UEFI prompt and select the disk as boot device
  - Remove the Talso ISO from the _Hardware_ tab in Proxmox so that in subsequent boots the nodes will never boot from ISO (this is currently not supprted by the Terraform provider)
- After reboot, retrieve the kubeconfig:
  ```bash
  talosctl kubeconfig -n 192.168.123.20 > ~/.kube/config
  export KUBECONFIG=$HOME/.kube/config
  kubectl get nodes
  ```

## Step 3: `talosctl bootstrap`

- Call `talosctl bootstrap -n 192.168.123.20` to install basic K8s components, after the control-plane node has rebooted

## Step 3: Bootstrap Cilium and Flux

- The created cluster won't become ready, since the CNI Cilium is missing
- Install Cilium and Flux via [../talos/bootstrap/bootstrap.sh](../talos/bootstrap/bootstrap.sh) and here only kept for explanation.
