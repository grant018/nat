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
$ConfirmPreference = 'None'
$env:NAT_OUTPUT_MODE = 'json'

# Top-level safety net. Without it, any unhandled error outside the main
# try/catch (Import-Module failure, syntax error, relay crash, etc.) exits
# silently with code 1 because the worker's stderr goes to its own (often
# invisible) console window - nothing makes it back to Node, and the UI
# just sees "pwsh exited unexpectedly". Write directly to the IPC file when
# in worker mode so the coordinator forwards it; otherwise straight to stdout.
trap {
    $errEvent = @{
        type    = 'fatal'
        message = "$($_.Exception.Message) | $($_.ScriptStackTrace)"
        ts      = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress
    if ($env:NAT_OUTPUT_FILE) {
        try { [System.IO.File]::AppendAllText($env:NAT_OUTPUT_FILE, $errEvent + "`n") } catch { }
    } else {
        try { [Console]::Out.WriteLine($errEvent); [Console]::Out.Flush() } catch { }
    }
    exit 1
}

# ---- Relay mode (Windows only) ------------------------------------------
# The Node-spawned process has no console window, so MSAL/WAM crashes on
# any interactive auth attempt. Fix: spawn a visible worker window (which
# DOES get a console HWND) and tail its NDJSON output back to our stdout.
# NAT_IS_WORKER is inherited by the child so it skips this block.
if (-not $IsMacOS -and -not $env:NAT_IS_WORKER) {
    $ipcFile = [System.IO.Path]::GetTempFileName()
    $env:NAT_IS_WORKER   = '1'
    $env:NAT_OUTPUT_FILE = $ipcFile

    $wArgs = [System.Collections.Generic.List[string]]::new()
    $wArgs.AddRange([string[]]@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
                                '-UserUPN',$UserUPN,'-LogPath',$LogPath))
    if ($DelegateUPN.Count -gt 0)     { $wArgs.AddRange([string[]]@('-DelegateUPN',($DelegateUPN -join ','))) }
    if ($AutoReplyMessage)             { $wArgs.AddRange([string[]]@('-AutoReplyMessage',$AutoReplyMessage)) }
    if ($LitigationHoldDays -ne 1825) { $wArgs.AddRange([string[]]@('-LitigationHoldDays',[string]$LitigationHoldDays)) }
    if ($LicensesOnly)                 { $wArgs.Add('-LicensesOnly') }
    if ($DryRun)                       { $wArgs.Add('-DryRun') }
    if ($PreflightOnly)                { $wArgs.Add('-PreflightOnly') }

    $proc = Start-Process 'pwsh' -ArgumentList $wArgs -PassThru
    $env:NAT_IS_WORKER   = ''
    $env:NAT_OUTPUT_FILE = ''

    $pos = 0L
    do {
        Start-Sleep -Milliseconds 150
        try {
            if ([System.IO.FileInfo]::new($ipcFile).Length -gt $pos) {
                $fs = [System.IO.FileStream]::new($ipcFile,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                $fs.Seek($pos, [System.IO.SeekOrigin]::Begin) | Out-Null
                $sr = [System.IO.StreamReader]::new($fs)
                while (-not $sr.EndOfStream) {
                    $line = $sr.ReadLine()
                    if ($line.Trim()) { [Console]::Out.WriteLine($line); [Console]::Out.Flush() }
                }
                $pos = $fs.Position; $sr.Dispose(); $fs.Dispose()
            }
        } catch {}
    } while (-not $proc.HasExited)

    Start-Sleep -Milliseconds 300    # final drain
    try {
        $fs = [System.IO.FileStream]::new($ipcFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $fs.Seek($pos, [System.IO.SeekOrigin]::Begin) | Out-Null
        $sr = [System.IO.StreamReader]::new($fs)
        while (-not $sr.EndOfStream) {
            $line = $sr.ReadLine()
            if ($line.Trim()) { [Console]::Out.WriteLine($line); [Console]::Out.Flush() }
        }
        $sr.Dispose(); $fs.Dispose()
    } catch {}

    Remove-Item $ipcFile -Force -ErrorAction SilentlyContinue
    exit ($proc.ExitCode ?? 0)
}
# ---- End relay mode -------------------------------------------------------

# Worker-mode startup beacon. If this event appears in the UI but no other
# events follow, we know the worker spawned but crashed before reaching the
# main workflow - which narrows the search to Import-Module / auth / module
# loading. If this never appears, Start-Process isn't actually launching a
# usable pwsh worker on this machine.
if ($env:NAT_IS_WORKER -and $env:NAT_OUTPUT_FILE) {
    $bootEvt = @{
        type    = 'log'
        level   = 'INFO'
        message = "Worker started (PID=$PID, pwsh=$($PSVersionTable.PSVersion))"
        ts      = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress
    try { [System.IO.File]::AppendAllText($env:NAT_OUTPUT_FILE, $bootEvt + "`n") } catch { }
}

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
