#!/bin/bash
set -euo pipefail

echo "Removing agent-not-ready taint from nodes..."
kubectl taint nodes --all node.cilium.io/agent-not-ready- --overwrite || true

echo "Installing Cilium CLI..."
echo "Installing Cilium with eBPF and Hubble..."
cilium install --version 1.18.6 \
  --set kubeProxyReplacement=true \
  --set ebpf.enabled=true

echo "Cilium installation completed."
echo "Waiting for Cilium to be fully ready..."
cilium status --wait

echo "Bootstrapping FluxCD to GitHub repository..."
flux bootstrap github --owner=rkschamer --repository=homelab --branch=main --path=./flux --personal
