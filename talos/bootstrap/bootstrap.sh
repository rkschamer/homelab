#!/bin/bash
set -euo pipefail

echo "Removing agent-not-ready taint from nodes..."
kubectl taint nodes --all node.cilium.io/agent-not-ready- --overwrite || true

echo "Installing Cilium CLI..."
echo "Installing Cilium with eBPF, Hubble and host firewall enabled..."
cilium install \
    --set cluster.name=homelab \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=true \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hostFirewall.enabled=true

echo "Cilium installation completed."
echo "Waiting for Cilium to be fully ready..."
cilium status --wait

echo "Showing Cilium ConfigMap. Check if this needs to be exported for GitOps into flux/installs/cilium-config.yaml"
kubectl get cm -n kube-system cilium-config -o yaml

echo "Bootstrapping FluxCD to GitHub repository..."
flux bootstrap github --owner=rkschamer --repository=homelab --branch=main --path=./flux --personal --token-auth=false
