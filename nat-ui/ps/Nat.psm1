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
    if ($env:NAT_OUTPUT_FILE) {
        # Worker mode: write to the IPC file the coordinator is tailing.
        [System.IO.File]::AppendAllText($env:NAT_OUTPUT_FILE, $json + "`n")
    } else {
        [Console]::Out.WriteLine($json)
        [Console]::Out.Flush()
    }
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

function Get-NatTokenClaims {
    # Decode the payload section of a JWT. Used to extract the UPN and tid
    # claims from an access token we acquired ourselves, so we can pass them
    # to Connect-ExchangeOnline (which needs UserPrincipalName + the token).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Token)
    $payload = $Token.Split('.')[1]
    $padding = (4 - ($payload.Length % 4)) % 4
    if ($padding) { $payload += '=' * $padding }
    $payload = $payload.Replace('-', '+').Replace('_', '/')
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
    return $json | ConvertFrom-Json
}

function Invoke-NatMacOAuth {
    <#
    .SYNOPSIS
        OAuth 2.0 authorization-code-with-PKCE flow for macOS.
    .DESCRIPTION
        MSAL.NET (bundled in the EXO and Graph modules) crashes on macOS 15+
        because its 'default OS browser' path returns PlatformNotSupportedException.
        We bypass MSAL by running the flow ourselves: open the auth URL via
        `open`, listen on localhost for the redirect, exchange the code for an
        access token, and hand the token back to the caller to plug into
        Connect-MgGraph / Connect-ExchangeOnline -AccessToken.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string[]]$Scopes,
        [string]$TenantId = 'common'
    )

    # PKCE: 32 random bytes -> base64url verifier; SHA256(verifier) -> challenge.
    $verifierBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($verifierBytes)
    $verifier  = [Convert]::ToBase64String($verifierBytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $challengeBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($challengeBytes).TrimEnd('=').Replace('+','-').Replace('/','_')

    # Bind a localhost listener on the first free port in 8400-8499. Microsoft's
    # public PowerShell client apps accept http://localhost:* as a redirect URI.
    $listener = [System.Net.HttpListener]::new()
    $port = 0
    foreach ($p in 8400..8499) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://localhost:$p/")
            $listener.Start()
            $port = $p
            break
        } catch {
            # Port in use; try the next one.
        }
    }
    if ($port -eq 0) {
        throw "Could not bind any localhost port in 8400-8499 for the OAuth callback."
    }
    $redirectUri = "http://localhost:$port/"
    $state = [Guid]::NewGuid().ToString()

    # offline_access gives a refresh token; harmless even if we don't use it.
    $scopeStr = (($Scopes + 'offline_access') | Select-Object -Unique) -join ' '
    $authParams = [ordered]@{
        client_id             = $ClientId
        response_type         = 'code'
        redirect_uri          = $redirectUri
        response_mode         = 'query'
        scope                 = $scopeStr
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
        prompt                = 'select_account'
    }
    $qs = ($authParams.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'
    $authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?$qs"

    try {
        Write-Step "Opening browser for sign-in (port $port)..." 'WARN'
        & open $authUrl 2>$null
        Write-Step 'Waiting up to 5 minutes for sign-in to complete in browser...'

        # GetContextAsync + Wait gives us a usable timeout (HttpListener.GetContext blocks indefinitely).
        $task = $listener.GetContextAsync()
        if (-not $task.Wait([TimeSpan]::FromMinutes(5))) {
            throw 'Sign-in timed out after 5 minutes.'
        }
        $context = $task.Result
        $authCode      = $context.Request.QueryString['code']
        $err           = $context.Request.QueryString['error']
        $errDesc       = $context.Request.QueryString['error_description']
        $stateReturned = $context.Request.QueryString['state']

        # Render a small confirmation page so the user sees something useful.
        $bodyHtml = if ($authCode) {
            "<html><body style='font-family:-apple-system,sans-serif;text-align:center;padding:60px;background:#0b0d10;color:#e5e7eb'><h1 style='color:#67e8f9'>Sign-in complete</h1><p>You can close this tab and return to the terminal.</p></body></html>"
        } else {
            # Crude HTML escaping - just strip angle brackets and ampersands.
            $msg = ("$err - $errDesc" -replace '[<>&]', '')
            "<html><body style='font-family:-apple-system,sans-serif;text-align:center;padding:60px;background:#0b0d10;color:#e5e7eb'><h1 style='color:#f87171'>Sign-in failed</h1><p>$msg</p></body></html>"
        }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($bodyHtml)
        $context.Response.ContentType = 'text/html; charset=utf-8'
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()

        if ($err)              { throw "OAuth error: $err - $errDesc" }
        if (-not $authCode)    { throw 'No authorization code returned by Microsoft Entra.' }
        if ($stateReturned -ne $state) { throw 'OAuth state mismatch (possible CSRF/replay).' }

        $tokenResp = Invoke-RestMethod -Method Post `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id     = $ClientId
                scope         = $scopeStr
                code          = $authCode
                redirect_uri  = $redirectUri
                grant_type    = 'authorization_code'
                code_verifier = $verifier
            }
        return $tokenResp.access_token
    }
    finally {
        try { $listener.Stop(); $listener.Close() } catch { }
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

    # IMPORTANT: connect EXO BEFORE Graph. Both modules use MSAL internally;
    # when Graph initializes MSAL first, EXO can inherit a polluted MSAL state
    # that surfaces as Get-ConnectionContext throwing NullReferenceException
    # (seen on Windows 11 26100 / pwsh 7.6 with ExchangeOnlineManagement 3.x).
    # Force-reloading the EXO module guarantees a clean MSAL initialization.
    # We also skip Get-ConnectionInformation entirely - in worker mode the
    # process is always fresh, and that cmdlet has a habit of throwing the
    # same NullRef when the module's internal state isn't fully set up yet.
    # Windows: MSAL's WAM/browser path works, just call the cmdlets normally.
    # macOS: MSAL's default-OS-browser path is broken on macOS 15+ (throws
    # PlatformNotSupportedException) and device code is widely blocked by
    # Conditional Access (AADSTS53003), so we run our own OAuth code-with-PKCE
    # flow and inject the resulting access token via -AccessToken. This
    # preserves per-admin attribution (token carries the admin's UPN).
    if ($Service -in 'All', 'Exo') {
        Write-Step 'Connecting to Exchange Online...'
        Remove-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue
        Import-Module ExchangeOnlineManagement -Force
        if ($IsMacOS) {
            # Public client ID for "Microsoft Office Exchange Online Powershell".
            $exoToken = Invoke-NatMacOAuth `
                -ClientId 'fb78d390-0c51-40cd-8e17-fdbfab77341b' `
                -Scopes  @('https://outlook.office365.com/.default')
            $claims = Get-NatTokenClaims -Token $exoToken
            $upn    = $claims.upn
            if (-not $upn) { $upn = $claims.preferred_username }
            if (-not $upn) { throw 'EXO access token did not contain a UPN claim.' }
            Connect-ExchangeOnline -AccessToken $exoToken -UserPrincipalName $upn -ShowBanner:$false | Out-Null
        } else {
            Connect-ExchangeOnline -ShowBanner:$false | Out-Null
        }
    }

    if ($Service -in 'All', 'Graph') {
        if (-not (Get-MgContext)) {
            Write-Step 'Connecting to Microsoft Graph...'
            if ($IsMacOS) {
                # Public client ID for "Microsoft Graph PowerShell".
                $graphToken = Invoke-NatMacOAuth `
                    -ClientId '14d82eec-204b-4c2f-b7e8-296a70dab67e' `
                    -Scopes  @(
                        'https://graph.microsoft.com/User.ReadWrite.All',
                        'https://graph.microsoft.com/Group.ReadWrite.All',
                        'https://graph.microsoft.com/GroupMember.ReadWrite.All',
                        'https://graph.microsoft.com/Directory.ReadWrite.All',
                        'https://graph.microsoft.com/Organization.Read.All'
                    )
                $secure = ConvertTo-SecureString $graphToken -AsPlainText -Force
                Connect-MgGraph -AccessToken $secure -NoWelcome | Out-Null
            } else {
                Connect-MgGraph -Scopes @(
                    'User.ReadWrite.All',
                    'Group.ReadWrite.All',
                    'GroupMember.ReadWrite.All',
                    'Directory.ReadWrite.All',
                    'Organization.Read.All'
                ) -NoWelcome | Out-Null
            }
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
