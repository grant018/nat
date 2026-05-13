<#
.SYNOPSIS
    Zero-to-running bootstrap for nat. Installs every prerequisite and
    launches the web UI.

.DESCRIPTION
    Run on a fresh Windows machine - no Git, Node, PowerShell 7, or
    Microsoft modules required up front. Uses winget for binaries.

    One-liner (Windows PowerShell 5.1 or pwsh):
        irm https://raw.githubusercontent.com/grant018/nat/main/bootstrap.ps1 | iex

    What it does:
      1. Confirms winget is available
      2. Installs PowerShell 7 if missing
      3. Installs Node.js LTS if missing
      4. Installs Microsoft.Graph + ExchangeOnlineManagement if missing
      5. Downloads the repo zip to %USERPROFILE%\nat
      6. Launches nat-ui\start.cmd (opens browser to localhost:5757)

    Re-running is safe: anything already installed is skipped, and the
    repo folder is updated in place.
#>

$ErrorActionPreference = 'Stop'

function Write-Status { param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[nat] $Msg" -ForegroundColor $Color
}
function Test-Cmd { param([string]$Name)
    try { $null = Get-Command $Name -ErrorAction Stop; $true } catch { $false }
}
function Install-Winget { param([string]$Id, [string]$Friendly)
    Write-Status "Installing $Friendly..." 'Yellow'
    & winget install --id $Id --silent --accept-source-agreements --accept-package-agreements --scope user
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Friendly (exit $LASTEXITCODE)."
    }
}

Write-Host ''
Write-Host '======================================' -ForegroundColor Cyan
Write-Host '  nat bootstrap' -ForegroundColor Cyan
Write-Host '======================================' -ForegroundColor Cyan
Write-Host ''

# --- winget gate ----------------------------------------------------------
if (-not (Test-Cmd 'winget')) {
    Write-Status 'winget is required but not found.' 'Red'
    Write-Host '  Install "App Installer" from the Microsoft Store, then re-run this command:' -ForegroundColor Yellow
    Write-Host '  https://apps.microsoft.com/detail/9NBLGGH4NNS1' -ForegroundColor Yellow
    return
}

# --- PowerShell 7 ---------------------------------------------------------
if (-not (Test-Cmd 'pwsh')) {
    Install-Winget 'Microsoft.PowerShell' 'PowerShell 7'
} else {
    Write-Status 'PowerShell 7 already installed.'
}

# --- Node.js LTS ----------------------------------------------------------
if (-not (Test-Cmd 'node')) {
    Install-Winget 'OpenJS.NodeJS.LTS' 'Node.js LTS'
} else {
    Write-Status 'Node.js already installed.'
}

# Refresh PATH so the just-installed tools are visible to this session
# and to anything we spawn from it.
$env:Path = ([System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
             [System.Environment]::GetEnvironmentVariable('Path', 'User'))

# --- Microsoft modules ----------------------------------------------------
$modules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Users.Actions',
    'Microsoft.Graph.Groups',
    'ExchangeOnlineManagement'
)
$missing = $modules | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
if ($missing.Count -gt 0) {
    Write-Status ("Installing PowerShell modules: {0}" -f ($missing -join ', ')) 'Yellow'
    # PSGallery is untrusted by default - skip the prompt without changing settings globally.
    Install-Module -Name $missing -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
} else {
    Write-Status 'PowerShell modules already installed.'
}

# --- Download repo --------------------------------------------------------
$installDir = Join-Path $env:USERPROFILE 'nat'
$zipUrl     = 'https://github.com/grant018/nat/archive/refs/heads/main.zip'
$tmpZip     = Join-Path $env:TEMP "nat-$([guid]::NewGuid().ToString('N')).zip"
$tmpDir     = Join-Path $env:TEMP "nat-$([guid]::NewGuid().ToString('N'))"

Write-Status "Downloading repo to $installDir..."
Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
$inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1

if (Test-Path $installDir) {
    # Preserve user-local content (Logs, node_modules) by copying the new
    # tree on top instead of wiping the folder.
    Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $installDir -Recurse -Force
    Write-Status "Updated existing install at $installDir." 'Green'
} else {
    Move-Item -Path $inner.FullName -Destination $installDir
    Write-Status "Installed to $installDir." 'Green'
}

Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

# --- Launch ---------------------------------------------------------------
$startCmd = Join-Path $installDir 'nat-ui\start.cmd'
if (-not (Test-Path $startCmd)) {
    Write-Status "Could not find $startCmd. Something went wrong during download." 'Red'
    return
}

Write-Status 'Launching nat-ui...' 'Green'
Write-Host ''
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$startCmd`"" -WorkingDirectory (Split-Path $startCmd)
