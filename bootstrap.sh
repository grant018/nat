#!/usr/bin/env bash
# Zero-to-running bootstrap for nat on macOS.
#
# Usage from a fresh Mac:
#   curl -fsSL https://raw.githubusercontent.com/grant018/nat/main/bootstrap.sh | bash
#
# What it does:
#   1. Installs Homebrew if missing
#   2. Installs PowerShell 7 if missing
#   3. Installs Node.js if missing
#   4. Installs Microsoft.Graph + ExchangeOnlineManagement if missing
#   5. Downloads the repo to ~/nat
#   6. Launches nat-ui/start.sh (opens browser to localhost:5757)
#
# Re-running is safe: anything already installed is skipped, and the repo
# folder is updated in place.

set -euo pipefail

# Homebrew runs a "cleanup" pass after every install that occasionally
# exits non-zero even when the install itself succeeded. Combined with
# set -e that silently aborts the bootstrap. Suppress the post-install
# cleanup and the noisy update check so brew exits cleanly.
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

c_cyan='\033[0;36m'
c_yellow='\033[0;33m'
c_red='\033[0;31m'
c_green='\033[0;32m'
c_off='\033[0m'

status() { printf "${c_cyan}[nat]${c_off} %s\n" "$1"; }
warn()   { printf "${c_yellow}[nat]${c_off} %s\n" "$1"; }
err()    { printf "${c_red}[nat]${c_off} %s\n" "$1" >&2; }
ok()     { printf "${c_green}[nat]${c_off} %s\n" "$1"; }

echo ""
echo "======================================"
echo "  nat bootstrap (macOS)"
echo "======================================"
echo ""

# --- macOS gate -----------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
  err "This installer is for macOS. On Windows use bootstrap.ps1; on Linux install dependencies manually."
  exit 1
fi

brew_shellenv() {
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

# --- Homebrew -------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  status "Installing Homebrew (you'll be prompted for your password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # The installer prints shell-init instructions but does not modify the
  # current session's PATH. Source it ourselves so subsequent brew calls work.
  brew_shellenv
else
  status "Homebrew already installed."
fi

# --- PowerShell 7 ---------------------------------------------------------
if ! command -v pwsh >/dev/null 2>&1; then
  status "Installing PowerShell 7..."
  brew install --cask powershell
  brew_shellenv
  hash -r
  if ! command -v pwsh >/dev/null 2>&1; then
    err "PowerShell installed but 'pwsh' is not on PATH. Open a new terminal and re-run."
    exit 1
  fi
else
  status "PowerShell 7 already installed."
fi

# --- Node.js --------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  status "Installing Node.js..."
  brew install node
  brew_shellenv
  hash -r
  if ! command -v node >/dev/null 2>&1; then
    err "Node installed but 'node' is not on PATH. Open a new terminal and re-run."
    exit 1
  fi
else
  status "Node.js already installed."
fi

# --- Microsoft modules ----------------------------------------------------
status "Checking PowerShell modules (this can take a few minutes on first run)..."
pwsh -NoProfile -Command "
\$modules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Users.Actions',
    'Microsoft.Graph.Groups',
    'ExchangeOnlineManagement'
)
\$missing = \$modules | Where-Object { -not (Get-Module -ListAvailable -Name \$_) }
if (\$missing.Count -gt 0) {
    Write-Host ('Installing: ' + (\$missing -join ', '))
    Install-Module -Name \$missing -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
} else {
    Write-Host 'All modules already installed.'
}
"

# --- Download repo --------------------------------------------------------
INSTALL_DIR="$HOME/nat"
ZIP_URL='https://github.com/grant018/nat/archive/refs/heads/main.zip'
TMP_ZIP="$(mktemp -t nat-XXXXXX).zip"
TMP_DIR="$(mktemp -d -t nat-XXXXXX)"

status "Downloading repo to $INSTALL_DIR..."
curl -fsSL "$ZIP_URL" -o "$TMP_ZIP"
unzip -q "$TMP_ZIP" -d "$TMP_DIR"
INNER="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

if [ -d "$INSTALL_DIR" ]; then
  # Copy on top so user-local Logs/ and node_modules/ are preserved.
  cp -R "$INNER"/* "$INSTALL_DIR"/
  cp -R "$INNER"/.gitignore "$INSTALL_DIR"/ 2>/dev/null || true
  ok "Updated existing install at $INSTALL_DIR."
else
  mv "$INNER" "$INSTALL_DIR"
  ok "Installed to $INSTALL_DIR."
fi

rm -f "$TMP_ZIP"
rm -rf "$TMP_DIR"

# Zip extraction drops the executable bit on shell scripts.
chmod +x "$INSTALL_DIR/nat-ui/start.sh" "$INSTALL_DIR/bootstrap.sh" 2>/dev/null || true

# --- Launch ---------------------------------------------------------------
ok "Launching nat-ui..."
echo ""
exec "$INSTALL_DIR/nat-ui/start.sh"
