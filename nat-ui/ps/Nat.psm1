<#
.SYNOPSIS
    Step functions extracted from nat.ps1.

.DESCRIPTION
    All M365 termination logic lives here. The CLI (nat.ps1) and the
    JSON-IO entrypoint (Invoke-NatTermination.ps1) both import this
    module and call the same functions.

    Set $env:NAT_OUTPUT_MODE = 'json' before importing/calling for
    machine-readable NDJSON output on stdout. Anything else (or unset)
    keeps the original coloured-console behaviour.
#>

$ErrorActionPreference = 'Stop'

function Send-NatEvent {
    <#
    .SYNOPSIS
        Emit one NDJSON event to stdout. No-op outside JSON mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [hashtable]$Data = @{}
    )
    if ($env:NAT_OUTPUT_MODE -ne 'json') { return }
    $payload = @{ type = $Type; ts = (Get-Date).ToString('o') }
    foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] }
    $json = $payload | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    if ($env:NAT_OUTPUT_MODE -eq 'json') {
        Send-NatEvent -Type 'log' -Data @{ level = $Level; message = $Message }
        return
    }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Cyan' }
    }
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

function Assert-RequiredModules {
    $required = 'Microsoft.Graph.Authentication',
                'Microsoft.Graph.Users',
                'Microsoft.Graph.Users.Actions',
                'Microsoft.Graph.Groups',
                'ExchangeOnlineManagement'
    $missing = $required | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missing) {
        throw "Missing required modules: $($missing -join ', '). Install with: Install-Module $($missing -join ', ') -Scope CurrentUser"
    }
}

function Connect-Services {
    # -Service controls which back-ends to connect to. Default 'All' = the
    # full termination workflow. 'Graph' = just Microsoft Graph (used by the
    # licenses-only flow, which has no EXO dependency). 'Exo' is rarely
    # needed on its own but kept for symmetry.
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'Graph', 'Exo')]
        [string]$Service = 'All'
    )

    if ($Service -in 'All', 'Graph') {
        if (-not (Get-MgContext)) {
            Write-Step 'Connecting to Microsoft Graph...'
            Connect-MgGraph -Scopes @(
                'User.ReadWrite.All',
                'Group.ReadWrite.All',
                'GroupMember.ReadWrite.All',
                'Directory.ReadWrite.All',
                'Organization.Read.All'
            ) -NoWelcome | Out-Null
        }
    }

    if ($Service -in 'All', 'Exo') {
        # Get-ConnectionInformation can throw "Error to log cannot be null/empty"
        # as a terminating error when EXO's in-session connection cache is in a
        # broken state (expired session, killed prior run, etc.). -ErrorAction
        # SilentlyContinue doesn't catch that flavour - wrap it ourselves and
        # treat any failure as "not connected" so we just (re)connect cleanly.
        $exo = $null
        try {
            $exo = Get-ConnectionInformation -ErrorAction Stop |
                Where-Object { $_.State -eq 'Connected' }
        } catch {
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
            $exo = $null
        }
        if (-not $exo) {
            Write-Step 'Connecting to Exchange Online...'
            Connect-ExchangeOnline -ShowBanner:$false | Out-Null
        }
    }
}

function Test-AlreadyOffboarded {
    # Read-only pre-flight. Returns a pscustomobject describing any signs that
    # this user has already been (partially) offboarded, so the caller can
    # decide whether to abort instead of running a series of no-ops that all
    # look successful.
    [CmdletBinding()]
    param([string]$UPN)

    $signals = @()

    try {
        $u = Get-MgUser -UserId $UPN -Property AccountEnabled -ErrorAction Stop
        if (-not $u.AccountEnabled) { $signals += 'Sign-in already blocked (AccountEnabled = False)' }
    } catch {
        # Non-fatal: if we can't read the user, the main flow will fail loudly anyway.
    }

    try {
        $mbx = Get-Mailbox -Identity $UPN -ErrorAction Stop
        if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') { $signals += 'Mailbox already converted to shared' }
        if ($mbx.LitigationHoldEnabled)                    { $signals += 'Litigation hold already enabled' }
    } catch {
        # Non-fatal: mailbox may be unreachable for unrelated reasons.
    }

    [pscustomobject]@{
        AlreadyOffboarded = ($signals.Count -gt 0)
        Signals           = $signals
    }
}

function Block-UserSignIn {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$UPN)
    Write-Step "Blocking sign-in for $UPN"
    $user = Get-MgUser -UserId $UPN -Property Id,AccountEnabled,DisplayName
    if ($PSCmdlet.ShouldProcess($UPN, 'Block sign-in and revoke sessions')) {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-Step "Sign-in blocked and sessions revoked for $($user.DisplayName)" 'OK'
    }
}

function Remove-UserFromAllGroups {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$UPN)
    Write-Step "Enumerating group memberships for $UPN"
    $user = Get-MgUser -UserId $UPN -Property Id
    $memberships = Get-MgUserMemberOf -UserId $user.Id -All

    $cloudGroups = @()
    $exoGroups   = @()

    foreach ($m in $memberships) {
        $odataType = $m.AdditionalProperties.'@odata.type'
        if ($odataType -ne '#microsoft.graph.group') { continue }

        $groupTypes      = @($m.AdditionalProperties.groupTypes)
        $mailEnabled     = [bool]$m.AdditionalProperties.mailEnabled
        $securityEnabled = [bool]$m.AdditionalProperties.securityEnabled
        $isDynamic       = $groupTypes -contains 'DynamicMembership'

        # Distribution lists and mail-enabled security groups must be removed via EXO.
        $isDL  = $mailEnabled -and ($groupTypes -notcontains 'Unified')
        $isM365 = $groupTypes -contains 'Unified'

        if ($isDynamic) {
            Write-Step "Skipping dynamic group '$($m.AdditionalProperties.displayName)' - membership is rule-based" 'WARN'
            continue
        }

        if ($isDL -or ($mailEnabled -and $securityEnabled)) {
            $exoGroups += [pscustomobject]@{
                Id          = $m.Id
                DisplayName = $m.AdditionalProperties.displayName
                Mail        = $m.AdditionalProperties.mail
            }
        } else {
            $cloudGroups += [pscustomobject]@{
                Id          = $m.Id
                DisplayName = $m.AdditionalProperties.displayName
                IsM365      = $isM365
            }
        }
    }

    Write-Step "Found $($cloudGroups.Count) cloud group(s) and $($exoGroups.Count) mail-enabled group(s) to remove"

    foreach ($g in $cloudGroups) {
        if ($PSCmdlet.ShouldProcess($g.DisplayName, "Remove $UPN from group")) {
            try {
                Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                Write-Step "Removed from $($g.DisplayName)" 'OK'
            } catch {
                Write-Step "Failed to remove from $($g.DisplayName): $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    foreach ($g in $exoGroups) {
        if (-not $g.Mail) { continue }
        if ($PSCmdlet.ShouldProcess($g.DisplayName, "Remove $UPN from distribution group")) {
            try {
                Remove-DistributionGroupMember -Identity $g.Mail -Member $UPN -BypassSecurityGroupManagerCheck -Confirm:$false -ErrorAction Stop
                Write-Step "Removed from $($g.DisplayName)" 'OK'
            } catch {
                # Graph's memberOf response sometimes returns an empty groupTypes
                # for Microsoft 365 Groups, so they get routed to the EXO branch
                # by mistake. EXO refuses with "not supported on GroupMailbox" -
                # fall back to the Graph cmdlet which DOES handle M365 groups.
                if ($_.Exception.Message -match 'GroupMailbox') {
                    try {
                        Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop
                        Write-Step "Removed from $($g.DisplayName) (via Graph - it's a M365 group)" 'OK'
                    } catch {
                        Write-Step "Failed to remove from $($g.DisplayName): $($_.Exception.Message)" 'ERROR'
                    }
                } else {
                    Write-Step "Failed to remove from $($g.DisplayName): $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}

function Set-TerminationAutoReply {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$UPN,
        [string]$Message
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Step 'No auto-reply message supplied - skipping' 'WARN'
        return
    }

    # EXO stores the auto-reply as HTML; plain newlines collapse to spaces
    # when rendered. Convert each line break to <br> so paragraphs survive.
    $htmlMessage = $Message -replace "`r`n|`r|`n", '<br>'

    Write-Step "Configuring auto-reply for $UPN"
    if ($PSCmdlet.ShouldProcess($UPN, 'Enable auto-reply')) {
        Set-MailboxAutoReplyConfiguration -Identity $UPN `
            -AutoReplyState Enabled `
            -InternalMessage $htmlMessage `
            -ExternalMessage $htmlMessage `
            -ExternalAudience All
        Write-Step 'Auto-reply enabled (internal + external)' 'OK'
    }
}

function Set-TerminationLitigationHold {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$UPN,
        [int]$Days
    )
    Write-Step "Placing $UPN on litigation hold for $Days days"
    if ($PSCmdlet.ShouldProcess($UPN, "Litigation hold ($Days days)")) {
        Set-Mailbox -Identity $UPN `
            -LitigationHoldEnabled $true `
            -LitigationHoldDuration $Days `
            -LitigationHoldOwner (Get-MgContext).Account
        Write-Step 'Litigation hold set' 'OK'
    }
}

function Convert-ToSharedMailbox {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$UPN)
    Write-Step "Converting $UPN to a shared mailbox"
    if ($PSCmdlet.ShouldProcess($UPN, 'Convert to shared mailbox')) {
        Set-Mailbox -Identity $UPN -Type Shared
        Write-Step 'Mailbox converted to Shared' 'OK'
    }
}

function Grant-DelegateAccess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$UPN,
        [string[]]$Delegate
    )
    if (-not $Delegate -or $Delegate.Count -eq 0) {
        Write-Step 'No delegates supplied - skipping permission grant' 'WARN'
        return
    }
    foreach ($d in $Delegate) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        Write-Step "Granting 'Read and manage' (FullAccess) to $d on $UPN"
        if ($PSCmdlet.ShouldProcess($UPN, "Grant FullAccess to $d")) {
            try {
                Add-MailboxPermission -Identity $UPN -User $d `
                    -AccessRights FullAccess -InheritanceType All `
                    -AutoMapping $true -Confirm:$false | Out-Null

                # Read it back to confirm the grant actually persisted.
                $existing = Get-MailboxPermission -Identity $UPN -User $d -ErrorAction SilentlyContinue
                if ($existing | Where-Object { $_.AccessRights -contains 'FullAccess' -and -not $_.IsInherited }) {
                    Write-Step "Access granted to $d (verified)" 'OK'
                } else {
                    Write-Step "Add-MailboxPermission returned success for $d but the grant is NOT visible on read-back. Check manually." 'ERROR'
                }
            } catch {
                Write-Step "Failed to grant access to ${d}: $($_.Exception.Message)" 'ERROR'
            }
        }
    }
}

function Remove-M365TerminationLicenses {
    <#
    .SYNOPSIS
        Removes all assigned licenses from a user. Run this AFTER the OneDrive
        transfer has been confirmed complete.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserUPN
    )

    # Only Graph is needed - assignLicense is a Graph REST call. Connecting
    # to EXO here would trigger an unnecessary auth window.
    Connect-Services -Service Graph
    $user = Get-MgUser -UserId $UserUPN -Property Id,AssignedLicenses,DisplayName
    $skus = $user.AssignedLicenses | Select-Object -ExpandProperty SkuId

    if (-not $skus) {
        Write-Step "No licenses assigned to $UserUPN" 'OK'
        return
    }

    Write-Step "Removing $($skus.Count) license SKU(s) from $($user.DisplayName)"
    if ($PSCmdlet.ShouldProcess($UserUPN, "Remove licenses: $($skus -join ', ')")) {
        # Set-MgUserLicense drops -AddLicenses @() from the serialized payload,
        # which the assignLicense endpoint rejects. Call the API directly so
        # both keys are guaranteed to be present.
        $skuJson = ($skus | ForEach-Object { '"' + $_.ToString() + '"' }) -join ','
        $body = '{"addLicenses":[],"removeLicenses":[' + $skuJson + ']}'
        Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/users/$($user.Id)/assignLicense" `
            -Body $body -ContentType 'application/json' | Out-Null
        Write-Step 'All licenses removed' 'OK'
    }
}

Export-ModuleMember -Function @(
    'Send-NatEvent',
    'Write-Step',
    'Assert-RequiredModules',
    'Connect-Services',
    'Test-AlreadyOffboarded',
    'Block-UserSignIn',
    'Remove-UserFromAllGroups',
    'Set-TerminationAutoReply',
    'Set-TerminationLitigationHold',
    'Convert-ToSharedMailbox',
    'Grant-DelegateAccess',
    'Remove-M365TerminationLicenses'
)
