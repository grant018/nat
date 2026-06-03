# Dependencies

The bootstrap scripts (`bootstrap.ps1` on Windows, `bootstrap.sh` on macOS) install everything in this list automatically. This document exists so the requirements are auditable without reading the installers, and so anyone setting up the project manually knows what to install.

## Operating system

| Platform | Versions tested |
|---|---|
| Windows | Windows 10 / 11 (x64) |
| macOS | macOS 13+ on Apple Silicon (arm64) and Intel (x64) |

## Runtimes

| Runtime | Minimum version | Used for | How `bootstrap.*` installs it |
|---|---|---|---|
| PowerShell | 7.0 | The termination workflow (`Nat.psm1`, `Invoke-NatTermination.ps1`) | Windows: `winget install Microsoft.PowerShell`. macOS: GitHub-release `.tar.gz` extracted to `~/.nat/pwsh/`. |
| Node.js | 18 LTS | The local web server and the SSE bridge to pwsh (`nat-ui/server/`) | Windows: `winget install OpenJS.NodeJS.LTS`. macOS: nodejs.org `.tar.gz` extracted to `~/.nat/node/`. |

## PowerShell modules

Installed to `CurrentUser` scope. Source: `Assert-RequiredModules` in [`nat-ui/ps/Nat.psm1`](nat-ui/ps/Nat.psm1).

| Module | Used for |
|---|---|
| `Microsoft.Graph.Authentication` | `Connect-MgGraph`, token / context state |
| `Microsoft.Graph.Users` | `Get-MgUser`, `Update-MgUser`, `Revoke-MgUserSignInSession` |
| `Microsoft.Graph.Users.Actions` | License assign / revoke via `assignLicense` |
| `Microsoft.Graph.Groups` | `Get-MgUserMemberOf`, `Remove-MgGroupMemberByRef` |
| `ExchangeOnlineManagement` | All mailbox operations: auto-reply, litigation hold, shared mailbox conversion, mailbox permissions |

## Node packages

Source: [`nat-ui/package.json`](nat-ui/package.json). Only one direct dependency — everything else is transitive.

| Package | Reason |
|---|---|
| `express` ^4.19.2 | HTTP server, static file serving, JSON body parsing, SSE response writes |

## External services

| Service | Endpoint | Purpose |
|---|---|---|
| Microsoft Entra ID (sign-in) | `https://login.microsoftonline.com/*` | OAuth token issuance for Graph and EXO |
| Microsoft Graph | `https://graph.microsoft.com/*` | User, group, license operations |
| Exchange Online | `https://outlook.office365.com/*` | Mailbox operations |
| OneDrive → SharePoint transfer API | `http://10.8.34.107:4173/api/external/jobs` | Step 7 of the workflow (internal Daxko service, API key in `nat-ui/server/index.js`) |

## Microsoft tenant requirements

The signed-in admin must hold roles that grant these Graph delegated scopes:

- `User.ReadWrite.All`
- `Group.ReadWrite.All`
- `GroupMember.ReadWrite.All`
- `Directory.ReadWrite.All`
- `Organization.Read.All`

…plus the **Exchange Recipient Administrator** (or higher) role for the EXO mailbox operations (`Set-Mailbox`, `Set-MailboxAutoReplyConfiguration`, `Add-MailboxPermission`, `Remove-DistributionGroupMember`).

Conditional Access notes:

- **Device code flow is not used** — tenants commonly block it (AADSTS53003).
- **Windows** uses WAM via MSAL (interactive broker, no extra UI for the admin once cached).
- **macOS** uses a custom OAuth 2.0 authorization-code-with-PKCE flow (see `Invoke-NatMacOAuth` in `Nat.psm1`) because MSAL.NET's default-OS-browser path is broken on macOS 15+. The admin signs in twice per session (once for Graph, once for EXO).

## Network requirements

Outbound HTTPS to:
- `login.microsoftonline.com`
- `graph.microsoft.com`
- `outlook.office365.com`
- `api.github.com` and `github.com` (bootstrap downloads only)
- `nodejs.org` (macOS bootstrap, Node tarball download)

Outbound HTTP to:
- `10.8.34.107:4173` (internal Daxko OneDrive transfer service)

Local-only:
- `127.0.0.1:5757` — the nat-ui web server
- `127.0.0.1:8400–8499` — macOS only, the OAuth callback listener used during sign-in

## Architecture support

| Architecture | Status |
|---|---|
| Windows x64 | Supported (bootstrap installs x64 builds) |
| Windows arm64 | Not tested — winget will install whatever it offers for the architecture, but pwsh/Node are downloaded as x64 in the current bootstrap |
| macOS arm64 (Apple Silicon) | Supported |
| macOS x64 (Intel) | Supported |
| Linux | Not supported — bootstrap.sh has a Darwin-only gate |
