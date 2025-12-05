# Use a Microsoft-provided base image with common tools
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG KUBERNETES_VERSION="1.34"

# Install system dependencies, git
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends curl wget git gnupg lsb-release software-properties-common openssl git-crypt


# Terraform installation
RUN wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list \
    && sudo apt update && sudo apt install terraform
RUN echo "Terraform version:" && terraform -version

# talosctl installation
RUN curl -sL https://talos.dev/install | sh

# Install kubectl
RUN apt-get update && apt-get install -y ca-certificates curl; \
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list; \
    apt-get update; \
    apt-get install -y kubectl

 # Install Helm
RUN curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
RUN echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
RUN sudo apt-get update
RUN sudo apt-get install helm

# Install FluxCD CLI
RUN curl -s https://fluxcd.io/install.sh | sudo bash
RUN flux --version

# Install Cilium CLI
RUN ARCH=$(dpkg --print-architecture) && \
    curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-${ARCH}.tar.gz{,.sha256sum} \
    && sha256sum --check cilium-linux-${ARCH}.tar.gz.sha256sum \
    && tar -xzvf cilium-linux-${ARCH}.tar.gz -C /usr/local/bin \
    && rm cilium-linux-${ARCH}.tar.gz cilium-linux-${ARCH}.tar.gz.sha256sum
RUN cilium version

# Install kubeseal (for Sealed Secrets)
RUN ARCH=$(dpkg --print-architecture) && \
    KUBESEAL_VERSION=$(curl -s "https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest" | grep -Po '"tag_name": "v\K[0-9.]+') \
    && wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz" \
    && tar -xvzf "kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz" kubeseal \
    && install -m 755 kubeseal /usr/local/bin/kubeseal \
    && rm "kubeseal-${KUBESEAL_VERSION}-linux-${ARCH}.tar.gz" kubeseal
RUN kubeseal --version

# Install Kompose (for converting Docker Compose files)
RUN ARCH=$(dpkg --print-architecture) && \
    curl -L https://github.com/kubernetes/kompose/releases/download/v1.32.0/kompose-linux-${ARCH} -o kompose \
    && install -o root -g root -m 0755 kompose /usr/local/bin/kompose
RUN echo "Kompose version:" && kompose version

# Clean up
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*
