#!/bin/bash
echo "Installing fzf from git..."
git clone --depth 1 https://github.com/junegunn/fzf.git /home/vscode/.fzf
/home/vscode/.fzf/install --all
echo "fzf installed: $(/home/vscode/.fzf/bin/fzf --version)"

echo "Setting ownership of Kubernetes config file..."
sudo chown vscode /home/vscode/.kube/config

echo "Configuring Git..."
git config --global user.name "rkschamer"
git config --global user.email "26967205+rkschamer@users.noreply.github.com"
git config --global core.autocrlf input
git config --global pull.rebase true
git config --global init.defaultBranch main
git config --global safe.directory /workspaces/homelab
echo "Git configuration complete."

echo "Setting up Talisman pre-commit hook..."
cd /workspaces/homelab
talisman --githook pre-commit
echo "Talisman pre-commit hook installed."

echo "Configuring shell aliases..."
cat >> /home/vscode/.bash_aliases << 'EOF'

# User-defined aliases
alias k='kubectl'
alias tf='terraform'
EOF
echo "Shell aliases configured."

echo "Configuring CLI tool autocompletion..."
mkdir -p /home/vscode/.bash_completion.d

# kubectl completion
kubectl completion bash > /home/vscode/.bash_completion.d/kubectl

# talosctl completion
talosctl completion bash > /home/vscode/.bash_completion.d/talosctl

# flux completion
flux completion bash > /home/vscode/.bash_completion.d/flux

# cilium completion
cilium completion bash > /home/vscode/.bash_completion.d/cilium

# kubeseal completion
kubeseal completion bash > /home/vscode/.bash_completion.d/kubeseal

# terraform completion (using tfenv if available, otherwise generate from terraform)
terraform -install-autocomplete 2>/dev/null || true

cat >> /home/vscode/.bashrc << 'EOF'

# History configuration
HISTSIZE=100000
HISTFILESIZE=100000
HISTFILE=/workspaces/homelab/.devcontainer/bash_history

# kubectl editor configuration
export KUBE_EDITOR="code --wait"

# CLI tool completions
for completion_file in /home/vscode/.bash_completion.d/*; do
    [ -f "$completion_file" ] && source "$completion_file"
done

# kubectl alias completion
complete -o bashdefault -o default -o nospace -F __start_kubectl k

# fzf keybindings and completion
eval "$(fzf --bash)"
EOF
echo "CLI tool autocompletion configured."
