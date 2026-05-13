<#
.SYNOPSIS
    JSON-IO entrypoint for the nat-ui web frontend.

.DESCRIPTION
    Runs the same workflow as nat.ps1 but emits one NDJSON event per
    line to stdout instead of coloured console text. The Node server
    spawns this script and forwards each event to the browser over SSE.

    Modes:
      (default)        Full 6-step termination
      -LicensesOnly    License removal only
      -PreflightOnly   Test-AlreadyOffboarded, emit a 'preflight' event, exit

.PARAMETER UserUPN
    UPN of the terminating user.

.PARAMETER DelegateUPN
    Zero or more delegate UPNs (FullAccess on the mailbox).

.PARAMETER AutoReplyMessage
    Auto-reply body. Empty string skips the step.

.PARAMETER LitigationHoldDays
    Litigation hold duration in days. Default 1825 (5 years).

.PARAMETER LicensesOnly
    Run only Remove-M365TerminationLicenses.

.PARAMETER PreflightOnly
    Connect, run Test-AlreadyOffboarded, emit one 'preflight' event, exit.

.PARAMETER LogPath
    Folder for the transcript. Defaults to ..\..\Logs relative to this file.
#>

# Deliberately NOT [CmdletBinding(SupportsShouldProcess)]. If WhatIfPreference
# is set at script scope it propagates into Import-Module / Connect-MgGraph
# internals and floods the log with hundreds of "What if: Update TypeData"
# / "What if: Set Alias" lines. We scope WhatIf to the actual step calls only.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$UserUPN,

    [string[]]$DelegateUPN = @(),

    [string]$AutoReplyMessage = '',

    [ValidateRange(1, 36500)]
    [int]$LitigationHoldDays = 1825,

    [switch]$LicensesOnly,

    [switch]$DryRun,

    [switch]$PreflightOnly,

    [string]$LogPath = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Logs')
)

$ErrorActionPreference = 'Stop'
$WhatIfPreference = $false
# The UI modal already gates the run, so suppress in-script confirmation
# prompts. Otherwise cmdlets with ConfirmImpact='High' (e.g.
# Remove-M365TerminationLicenses) block forever on a stdin prompt that the
# Node-spawned child process can never answer.
$ConfirmPreference = 'None'
$env:NAT_OUTPUT_MODE = 'json'

Import-Module (Join-Path $PSScriptRoot 'Nat.psm1') -Force -DisableNameChecking

function Invoke-NatStep {
    param(
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $start = Get-Date
    Send-NatEvent -Type 'step-start' -Data @{ step = $StepId }
    try {
        & $Action
        $ms = [int]((Get-Date) - $start).TotalMilliseconds
        Send-NatEvent -Type 'step-end' -Data @{ step = $StepId; status = 'ok'; durationMs = $ms }
    } catch {
        $ms = [int]((Get-Date) - $start).TotalMilliseconds
        $msg = $_.Exception.Message
        Send-NatEvent -Type 'step-end' -Data @{ step = $StepId; status = 'fail'; durationMs = $ms; error = $msg }
        throw
    }
}

$transcript = $null
try {
    Assert-RequiredModules

    if ($PreflightOnly) {
        Connect-Services
        $pf = Test-AlreadyOffboarded -UPN $UserUPN
        Send-NatEvent -Type 'preflight' -Data @{
            alreadyOffboarded = [bool]$pf.AlreadyOffboarded
            signals           = @($pf.Signals)
        }
        Send-NatEvent -Type 'done' -Data @{ status = 'success' }
        return
    }

    if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }
    $transcript = Join-Path $LogPath ("termination-{0}-{1:yyyyMMdd-HHmmss}.log" -f ($UserUPN -replace '[^\w]', '_'), (Get-Date))
    Start-Transcript -Path $transcript -Append | Out-Null

    if ($LicensesOnly) {
        Write-Step "=== License-removal pass for $UserUPN ===" 'OK'
        Invoke-NatStep -StepId 'remove-licenses' -Action {
            Remove-M365TerminationLicenses -UserUPN $UserUPN -WhatIf:$DryRun
        }
        Write-Step "=== License-removal pass complete ===" 'OK'
        Send-NatEvent -Type 'done' -Data @{ status = 'success'; transcript = $transcript }
        return
    }

    Connect-Services

    # Pre-flight signals are surfaced but never abort - the UI gates that
    # decision before the user submits, so by this point we proceed.
    $pf = Test-AlreadyOffboarded -UPN $UserUPN
    if ($pf.AlreadyOffboarded) {
        Send-NatEvent -Type 'preflight' -Data @{
            alreadyOffboarded = $true
            signals           = @($pf.Signals)
        }
        Write-Step "$UserUPN appears to already be (partially) offboarded:" 'WARN'
        foreach ($s in $pf.Signals) { Write-Step "  - $s" 'WARN' }
    }

    Write-Step "=== Termination workflow starting for $UserUPN ===" 'OK'

    Invoke-NatStep -StepId 'block-signin'    -Action { Block-UserSignIn              -UPN $UserUPN -WhatIf:$DryRun }
    Invoke-NatStep -StepId 'remove-groups'   -Action { Remove-UserFromAllGroups      -UPN $UserUPN -WhatIf:$DryRun }
    Invoke-NatStep -StepId 'auto-reply'      -Action { Set-TerminationAutoReply      -UPN $UserUPN -Message $AutoReplyMessage -WhatIf:$DryRun }
    Invoke-NatStep -StepId 'litigation-hold' -Action { Set-TerminationLitigationHold -UPN $UserUPN -Days $LitigationHoldDays -WhatIf:$DryRun }
    Invoke-NatStep -StepId 'convert-shared'  -Action { Convert-ToSharedMailbox       -UPN $UserUPN -WhatIf:$DryRun }
    Invoke-NatStep -StepId 'grant-delegates' -Action { Grant-DelegateAccess          -UPN $UserUPN -Delegate $DelegateUPN -WhatIf:$DryRun }

    Write-Step "=== Termination workflow complete for $UserUPN ===" 'OK'
    Write-Step "NEXT: once OneDrive transfer is confirmed, run licenses-only for $UserUPN" 'WARN'

    Send-NatEvent -Type 'done' -Data @{ status = 'success'; transcript = $transcript }
}
catch {
    Send-NatEvent -Type 'fatal' -Data @{ message = $_.Exception.Message; transcript = $transcript }
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
