#!/bin/bash
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

echo "Configuring shell aliases..."
cat >> /home/vscode/.bash_aliases << 'EOF'

# User-defined aliases
alias k='kubectl'
alias tf='terraform'
EOF
echo "Shell aliases configured."
