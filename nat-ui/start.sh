#!/usr/bin/env bash
# Launcher for nat-ui on macOS / Linux. Windows uses start.cmd.

set -euo pipefail

cd "$(dirname "$0")"

# Pick up user-local tool installs that bootstrap.sh dropped under ~/.nat
# (pwsh and node tarballs). Avoids requiring the user to mutate ~/.zshrc.
if [ -d "$HOME/.nat/pwsh" ]; then
  export PATH="$HOME/.nat/pwsh:$PATH"
fi
if [ -d "$HOME/.nat/node/bin" ]; then
  export PATH="$HOME/.nat/node/bin:$PATH"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required. Re-run bootstrap.sh to install it."
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is required. Re-run bootstrap.sh to install it."
  exit 1
fi

if [ ! -d "node_modules/express" ]; then
  echo "Installing dependencies..."
  npm install --omit=dev --no-audit --no-fund
fi

export NAT_OPEN_BROWSER=1
exec node server/index.js
