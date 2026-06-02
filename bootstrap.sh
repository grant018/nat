#!/usr/bin/env bash
# Zero-to-running bootstrap for nat on macOS.
#
# Usage from a fresh Mac:
#   curl -fsSL https://raw.githubusercontent.com/grant018/nat/main/bootstrap.sh | bash
#
# What it does:
#   1. Installs PowerShell 7 tarball into ~/.nat/pwsh if missing
#   2. Installs Node.js LTS tarball into ~/.nat/node if missing
#   3. Installs Microsoft.Graph + ExchangeOnlineManagement (CurrentUser scope)
#   4. Downloads the repo to ~/nat
#   5. Launches nat-ui/start.sh (opens browser to localhost:5757)
#
# Key design choice: NO Homebrew, NO sudo. Everything lives under the
# user's home directory. This avoids managed-Mac permission problems
# under /usr/local that MDM tools (Jamf etc.) re-apply periodically.
#
# Re-running is safe: tools already on PATH are kept; the repo folder
# is updated in place.

set -euo pipefail

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

# Everything user-local goes here.
NAT_LOCAL="$HOME/.nat"
mkdir -p "$NAT_LOCAL"

# Detect architecture once.
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  arm64)  PWSH_ARCH="arm64"; NODE_ARCH="arm64" ;;
  x86_64) PWSH_ARCH="x64";   NODE_ARCH="x64" ;;
  *)      err "Unsupported architecture: $ARCH_RAW"; exit 1 ;;
esac

# Prepend the user-local tool dirs to PATH for this session. start.sh
# does the same on every launch so the user never has to mutate ~/.zshrc.
export PATH="$NAT_LOCAL/pwsh:$NAT_LOCAL/node/bin:$PATH"

# --- PowerShell 7 (tarball, no sudo) --------------------------------------
install_pwsh_userlocal() {
  local asset_url tmp_tar
  status "Locating the latest PowerShell release for $ARCH_RAW..."
  asset_url="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
    | grep -oE "https://github.com/PowerShell/PowerShell/releases/download/[^\"]*-osx-${PWSH_ARCH}\.tar\.gz" \
    | head -n 1)"
  if [ -z "$asset_url" ]; then
    err "Could not find a PowerShell tarball for arch=$PWSH_ARCH."
    err "Manual install: https://github.com/PowerShell/PowerShell/releases/latest"
    exit 1
  fi

  tmp_tar="$(mktemp -t powershell-XXXXXX).tar.gz"
  status "Downloading $(basename "$asset_url")..."
  curl -fsSL "$asset_url" -o "$tmp_tar"

  status "Extracting PowerShell 7 to $NAT_LOCAL/pwsh..."
  rm -rf "$NAT_LOCAL/pwsh"
  mkdir -p "$NAT_LOCAL/pwsh"
  tar xzf "$tmp_tar" -C "$NAT_LOCAL/pwsh"
  chmod +x "$NAT_LOCAL/pwsh/pwsh"
  rm -f "$tmp_tar"
}

# Use existing pwsh if it actually runs. The `command -v` check alone isn't
# enough - a broken Homebrew/MDM install can leave a non-functional binary
# on PATH that fails on first invocation.
if command -v pwsh >/dev/null 2>&1 && pwsh -NoProfile -NoLogo -Command 'exit 0' >/dev/null 2>&1; then
  status "PowerShell 7 already installed at $(command -v pwsh)."
else
  install_pwsh_userlocal
fi

# --- Node.js LTS (tarball, no sudo) ---------------------------------------
get_node_lts_version() {
  # Parse nodejs.org's dist index for the most recent release where lts != false.
  # Pure-shell JSON parsing: brittle but no python dependency.
  local v
  v=$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null \
        | tr -d '\n' \
        | sed 's/},{/}\n{/g' \
        | grep -v '"lts":false' \
        | head -1 \
        | grep -oE '"version":"v[0-9]+\.[0-9]+\.[0-9]+"' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$v" ]; then
    err "Could not determine latest Node.js LTS version from nodejs.org/dist/index.json."
    return 1
  fi
  printf '%s' "$v"
}

install_node_userlocal() {
  local version tarball_url tmp_tar
  status "Locating the latest Node.js LTS release..."
  version="$(get_node_lts_version)"
  tarball_url="https://nodejs.org/dist/$version/node-$version-darwin-$NODE_ARCH.tar.gz"

  tmp_tar="$(mktemp -t nodejs-XXXXXX).tar.gz"
  status "Downloading $(basename "$tarball_url")..."
  curl -fsSL "$tarball_url" -o "$tmp_tar"

  status "Extracting Node.js to $NAT_LOCAL/node..."
  rm -rf "$NAT_LOCAL/node"
  mkdir -p "$NAT_LOCAL/node"
  # --strip-components=1 drops the leading node-vX.Y.Z-darwin-arch/ folder.
  tar xzf "$tmp_tar" -C "$NAT_LOCAL/node" --strip-components=1
  rm -f "$tmp_tar"
}

if command -v node >/dev/null 2>&1 && node --version >/dev/null 2>&1; then
  status "Node.js already installed at $(command -v node)."
else
  install_node_userlocal
fi

# Re-resolve commands after PATH additions.
hash -r

# --- Microsoft modules (CurrentUser scope, no admin) ----------------------
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
