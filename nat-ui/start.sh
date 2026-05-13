#!/usr/bin/env bash
# Launcher for nat-ui on macOS / Linux. Windows uses start.cmd.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required. Install it (e.g. 'brew install node') and re-run."
  exit 1
fi

if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is required. Install it (e.g. 'brew install --cask powershell') and re-run."
  exit 1
fi

if [ ! -d "node_modules/express" ]; then
  echo "Installing dependencies..."
  npm install --omit=dev --no-audit --no-fund
fi

URL="http://localhost:5757"
case "$(uname)" in
  Darwin) open "$URL" >/dev/null 2>&1 || true ;;
  Linux)  xdg-open "$URL" >/dev/null 2>&1 || true ;;
esac

exec node server/index.js
