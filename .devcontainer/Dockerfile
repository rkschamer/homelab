# Use a Microsoft-provided base image with common tools
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Install system dependencies, git
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends curl wget git gnupg lsb-release software-properties-common openssl

# Terraform installation
RUN wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list \
    && sudo apt update && sudo apt install terraform
RUN echo "Terraform version:" && terraform -version

# Install kubectl
# RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
#     && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# # Install Helm
# RUN curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null \
#     && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | tee /etc/apt/sources.list.d/helm-stable-debian.list \
#     && apt-get update && apt-get -y install helm

# # Install FluxCD CLI
# RUN curl -s https://fluxcd.io/install.sh | bash

# # Install Cilium CLI
# RUN curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz{,.sha256sum} \
#     && sha256sum --check cilium-linux-amd64.tar.gz.sha256sum \
#     && tar -xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin \
#     && rm cilium-linux-amd64.tar.gz{,.sha256sum}

# # Install kubeseal (for Sealed Secrets)
# RUN KUBESEAL_VERSION=$(curl -s "https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest" | grep -Po '"tag_name": "v\K[0-9.]+') \
#     && wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" \
#     && tar -xvzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal \
#     && install -m 755 kubeseal /usr/local/bin/kubeseal

# # Install Kompose (for converting Docker Compose files)
# RUN curl -L https://github.com/kubernetes/kompose/releases/download/v1.32.0/kompose-linux-amd64 -o kompose \
#     && install -o root -g root -m 0755 kompose /usr/local/bin/kompose

# Clean up
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*
