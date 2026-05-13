<#
.SYNOPSIS
    Automates the Microsoft 365 termination / offboarding workflow.

.DESCRIPTION
    Performs the standard offboarding steps for a departing user, in this
    fixed order:
      1. Block Entra ID / O365 sign-in and revoke active sessions
      2. Remove the user from all groups (security + M365 + distribution)
      3. Configure an internal + external auto-reply (if a message is given)
      4. Place the mailbox on litigation hold (default 1825 days = 5 years)
      5. Convert the mailbox to a shared mailbox
      6. Grant one or more "Read and manage" delegates FullAccess on the
         (now-shared) mailbox

    Conversion happens before the delegate grant because some tenants drop
    newly-added FullAccess permissions when the mailbox recipient type is
    changed. Granting on the already-converted shared mailbox is stable.

    A separate run with -LicensesOnly removes all assigned licenses. This
    is intentionally split from the main flow so it can be performed AFTER
    the OneDrive content transfer has been confirmed complete.

    On launch the script collects any missing inputs interactively (UPN,
    delegates, auto-reply text), shows a summary, and asks for confirmation
    before any change is made. Anything passed on the command line skips
    its prompt. Use -WhatIf for a zero-impact dry run.

    Step logic lives in nat-ui\ps\Nat.psm1 and is shared with the local
    web UI (nat-ui\start.cmd). Edits to behaviour belong in the module.

    Requires the Microsoft.Graph and ExchangeOnlineManagement modules and
    an account with User Admin, Exchange Admin, Groups Admin, and License
    Admin roles. Litigation hold further requires the terminating user to
    have an Exchange Online Plan 2 entitlement (E3, E5, or EOA add-on).

.PARAMETER UserUPN
    UPN of the terminating user (e.g. jdoe@contoso.com). Prompted for if
    omitted.

.PARAMETER DelegateUPN
    One or more UPNs to grant FullAccess ("Read and manage" in the M365
    admin centre) on the mailbox before it is converted to shared. Pass a
    single UPN or a comma-separated list, e.g.
    -DelegateUPN 'a@x.com','b@x.com'. Prompted for if omitted; press Enter
    at the prompt to skip.

.PARAMETER AutoReplyMessage
    Body of the auto-reply. If supplied, auto-reply is enabled for both
    internal and external senders. Prompted for if omitted; press Enter at
    the prompt to skip.

.PARAMETER LitigationHoldDays
    Litigation hold duration in days. Defaults to 1825 (5 years). Not
    prompted for - override on the command line if a different duration
    is ever needed.

.PARAMETER LicensesOnly
    Switch. Runs only the license-removal pass against -UserUPN. Use after
    the OneDrive transfer for the departing user has been confirmed
    complete. The main termination flow is skipped in this mode.

.PARAMETER LogPath
    Folder where a per-user transcript is written. Defaults to a "Logs"
    folder beside this script.

.EXAMPLE
    # Fully interactive - prompts for UPN, delegates, and auto-reply
    .\nat.ps1

.EXAMPLE
    # Zero-impact dry run; reads everything, writes nothing
    .\nat.ps1 -WhatIf

.EXAMPLE
    # Fully scripted (skips prompts)
    .\nat.ps1 -UserUPN jdoe@contoso.com `
        -DelegateUPN 'supervisor@contoso.com','coworker@contoso.com' `
        -AutoReplyMessage 'John Doe is no longer with the company. Please contact supervisor@contoso.com.'

.EXAMPLE
    # Later, after the OneDrive transfer is confirmed complete:
    .\nat.ps1 -UserUPN jdoe@contoso.com -LicensesOnly
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$UserUPN,

    [Parameter()]
    [ValidatePattern('^(|[^@\s]+@[^@\s]+\.[^@\s]+)$')]
    [string[]]$DelegateUPN,

    [Parameter()]
    [string]$AutoReplyMessage,

    [Parameter()]
    [ValidateRange(1, 36500)]
    [int]$LitigationHoldDays = 1825,

    [Parameter()]
    [switch]$LicensesOnly,

    [Parameter()]
    [string]$LogPath = (Join-Path $PSScriptRoot 'Logs')
)

$ErrorActionPreference = 'Stop'

# Load shared step logic. Output stays in console mode (coloured Write-Host).
Import-Module (Join-Path $PSScriptRoot 'nat-ui\ps\Nat.psm1') -Force -DisableNameChecking

#region --- Interactive input helpers (CLI-only) ------------------------------

function Read-RequiredUPN {
    param([string]$Prompt, [string]$Existing)
    if (-not [string]::IsNullOrWhiteSpace($Existing)) { return $Existing }
    while ($true) {
        $value = (Read-Host $Prompt).Trim()
        if ($value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return $value }
        Write-Host '  Not a valid UPN. Try again.' -ForegroundColor Yellow
    }
}

function Read-OptionalUPNList {
    param([string]$Prompt, [string[]]$Existing)
    if ($Existing -and $Existing.Count -gt 0) { return $Existing }
    while ($true) {
        $value = (Read-Host "$Prompt (comma-separated, Enter to skip)").Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return @() }
        $candidates = @($value -split '[,;]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $bad = $candidates | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' }
        if ($bad) {
            Write-Host "  Not a valid UPN: $($bad -join ', '). Try again." -ForegroundColor Yellow
            continue
        }
        return $candidates
    }
}

function Read-OptionalText {
    param([string]$Prompt, [string]$Existing)
    if (-not [string]::IsNullOrWhiteSpace($Existing)) { return $Existing }
    Write-Host "$Prompt"
    Write-Host '  Enter the message line-by-line and press Enter after each line.' -ForegroundColor DarkGray
    Write-Host '  Blank lines are kept as paragraph breaks. Type END on its own line when done.' -ForegroundColor DarkGray
    Write-Host '  To skip the auto-reply entirely, type END as the first line.' -ForegroundColor DarkGray
    $lines = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $line = Read-Host
        if ($line -eq 'END') { break }
        [void]$lines.Add($line)
    }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`r`n")
}

#endregion

#region --- Main flow ---------------------------------------------------------

Assert-RequiredModules

if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

# --- Interactive input collection -------------------------------------------
# Anything passed on the command line is kept; missing values are prompted.
Write-Host ''
Write-Host '=== Termination input collection ===' -ForegroundColor Cyan

$UserUPN = Read-RequiredUPN 'UPN of departing user' $UserUPN

if (-not $LicensesOnly) {
    $AutoReplyMessage = Read-OptionalText 'Auto-reply message' $AutoReplyMessage

    $_delegates = Read-OptionalUPNList 'UPN(s) for Read-and-manage delegates' $DelegateUPN
    if ($_delegates -and $_delegates.Count -gt 0) { $DelegateUPN = $_delegates }
    Remove-Variable _delegates -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
Write-Host ('  UserUPN              : {0}' -f $UserUPN)
if ($LicensesOnly) {
    Write-Host '  Mode                 : LicensesOnly (post-OneDrive cleanup)'
} else {
    Write-Host ('  DelegateUPN          : {0}' -f $(if ($DelegateUPN -and $DelegateUPN.Count -gt 0) { $DelegateUPN -join ', ' } else { '(none)' }))
    Write-Host ('  AutoReplyMessage     : {0}' -f $(if ($AutoReplyMessage) { ($AutoReplyMessage -replace "`r?`n", ' \n ') } else { '(none)' }))
    Write-Host ('  LitigationHoldDays   : {0}' -f $LitigationHoldDays)
}
if ($WhatIfPreference) { Write-Host '  -WhatIf              : DRY RUN - no changes will be made' -ForegroundColor Yellow }
Write-Host ''

if ((Read-Host 'Proceed? (Y/N)') -notmatch '^[Yy]') {
    Write-Host 'Aborted by user.' -ForegroundColor Yellow
    return
}

$transcript = Join-Path $LogPath ("termination-{0}-{1:yyyyMMdd-HHmmss}.log" -f ($UserUPN -replace '[^\w]', '_'), (Get-Date))
Start-Transcript -Path $transcript -Append | Out-Null

try {
    if ($LicensesOnly) {
        Write-Step "=== License-removal pass for $UserUPN ===" 'OK'
        Remove-M365TerminationLicenses -UserUPN $UserUPN
        Write-Step "=== License-removal pass complete ===" 'OK'
        return
    }

    Connect-Services

    # Pre-flight: detect users that have already been (partially) offboarded.
    # Without this check the script's idempotent steps all return success even
    # when nothing actually changes, which can read as a successful run when
    # in fact no action was needed.
    $preflight = Test-AlreadyOffboarded -UPN $UserUPN
    if ($preflight.AlreadyOffboarded) {
        Write-Step "$UserUPN appears to already be (partially) offboarded:" 'WARN'
        foreach ($s in $preflight.Signals) { Write-Host "    - $s" -ForegroundColor Yellow }
        Write-Step 'Some items have already been completed - these steps will be no-ops that still report OK.' 'WARN'
        if ((Read-Host 'Continue anyway? (Y/N)') -notmatch '^[Yy]') {
            Write-Step 'Aborted by user - no changes made.' 'OK'
            return
        }
    }

    Write-Step "=== Termination workflow starting for $UserUPN ===" 'OK'

    # Steps 1-5 must complete before the mailbox is converted to shared (6).
    # Licenses are removed in a separate -LicensesOnly run after the OneDrive
    # transfer is confirmed complete.
    Block-UserSignIn              -UPN $UserUPN                              # 1
    Remove-UserFromAllGroups      -UPN $UserUPN                              # 2
    Set-TerminationAutoReply      -UPN $UserUPN -Message $AutoReplyMessage   # 3
    Set-TerminationLitigationHold -UPN $UserUPN -Days $LitigationHoldDays    # 4
    Convert-ToSharedMailbox       -UPN $UserUPN                              # 5
    Grant-DelegateAccess          -UPN $UserUPN -Delegate $DelegateUPN       # 6

    Write-Step "=== Termination workflow complete for $UserUPN ===" 'OK'
    Write-Step "NEXT: once OneDrive transfer is confirmed, run:" 'WARN'
    Write-Step "  .\nat.ps1 -UserUPN $UserUPN -LicensesOnly" 'WARN'
}
catch {
    Write-Step "FATAL: $($_.Exception.Message)" 'ERROR'
    throw
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Transcript: $transcript" -ForegroundColor DarkGray
}

#endregion
