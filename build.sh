#!/usr/bin/env bash
set -euo pipefail

ZOLA_VERSION='0.22.1'

echo "Installing Zola ${ZOLA_VERSION}..."

# Download
curl -sL -o "zola.tar.gz" "https://github.com/getzola/zola/releases/download/v${ZOLA_VERSION}/zola-v${ZOLA_VERSION}-x86_64-unknown-linux-gnu.tar.gz"

# Extract
mkdir -p "${HOME}/.local/bin"
tar -xzf zola.tar.gz -C "${HOME}/.local/bin"
rm zola.tar.gz

export PATH="${HOME}/.local/bin:${PATH}"

echo "Building the site..."
zola build -f
