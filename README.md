# nat

Automates the Microsoft 365 termination / offboarding workflow for a departing user. Ships as both a PowerShell CLI (`nat.ps1`) and a local web UI (`nat-ui/`) that runs in your browser.

What the workflow does:

1. Block Entra ID / O365 sign-in and revoke active sessions
2. Remove the user from every group (security, M365, distribution)
3. Configure an internal + external auto-reply
4. Place the mailbox on litigation hold (default 5 years)
5. Convert the mailbox to a shared mailbox
6. Grant "Read and manage" (FullAccess) delegates on the now-shared mailbox

A separate **Licenses-only** run handles license removal after the OneDrive transfer is complete.

---

## Install + run (one command)

### Windows

Open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/grant018/nat/main/bootstrap.ps1 | iex
```

Installs PowerShell 7, Node.js, the Microsoft modules, downloads the repo to `%USERPROFILE%\nat`, and opens the app at <http://localhost:5757>.

Subsequent runs:

```powershell
cd $env:USERPROFILE\nat\nat-ui
.\start.cmd
```

### macOS

Open **Terminal** and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/grant018/nat/main/bootstrap.sh | bash
```

Installs Homebrew (if missing), PowerShell 7, Node.js, the Microsoft modules, downloads the repo to `~/nat`, and opens the app at <http://localhost:5757>.

Subsequent runs:

```bash
~/nat/nat-ui/start.sh
```

The first run takes a couple of minutes (mostly the Microsoft modules). Re-running the bootstrap is safe — it skips anything already installed and updates the repo in place.

---

## Using the web UI

1. Enter the departing user's UPN (e.g. `john.doe@daxko.com`).
2. Optionally add delegates, an auto-reply message, and a litigation hold duration.
3. Toggle **Dry run** at the top of the form if you want to see what *would* happen without making any changes.
4. Click **Review and run**, confirm the summary, and watch the 6 steps run live.
5. After the OneDrive transfer is confirmed complete, switch to the **Licenses only** tab and run again on the same user to strip the licenses.

A full transcript is saved to `Logs\` next to `nat.ps1` for every run.

You'll be prompted to sign in to Microsoft 365 the first time the script connects to Graph and Exchange Online. A browser window will pop up automatically.

---

## Using the CLI instead

If you'd rather skip the web UI, run `nat.ps1` from `pwsh` on either platform (use `./nat.ps1` on Mac, `.\nat.ps1` on Windows):

```powershell
# Fully interactive - prompts for everything
./nat.ps1

# Dry run
./nat.ps1 -WhatIf

# Fully scripted
./nat.ps1 -UserUPN john.doe@daxko.com `
    -DelegateUPN 'supervisor@daxko.com','coworker@daxko.com' `
    -AutoReplyMessage 'John is no longer with the company. Contact supervisor@daxko.com.'

# Licenses-only pass (after OneDrive transfer)
./nat.ps1 -UserUPN john.doe@daxko.com -LicensesOnly
```

---

## Permissions required

The signed-in admin account needs:

- User Admin
- Exchange Admin
- Groups Admin
- License Admin

Litigation hold additionally requires the departing user to have an **Exchange Online Plan 2** entitlement (E3, E5, or EOA add-on).

---

## Manual install (advanced)

If you don't want to use the bootstrap script, install these manually and then run `nat-ui/start.cmd` (Windows) or `nat-ui/start.sh` (Mac):

- **PowerShell 7+**
  - Windows: `winget install Microsoft.PowerShell` or <https://aka.ms/powershell>
  - Mac: `brew install --cask powershell`
- **Node.js LTS**
  - Windows: `winget install OpenJS.NodeJS.LTS` or <https://nodejs.org/>
  - Mac: `brew install node`
- **Microsoft modules** — run in `pwsh` (same on both platforms):
  ```powershell
  Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users,
                 Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups,
                 ExchangeOnlineManagement -Scope CurrentUser
  ```

---

## Troubleshooting

**Bootstrap says "winget is required but not found"** (Windows)
Install the **App Installer** package from the Microsoft Store, then re-run the one-liner. <https://apps.microsoft.com/detail/9NBLGGH4NNS1>

**Mac: `start.sh` is "permission denied"**
The file isn't executable. Run `chmod +x ~/nat/nat-ui/start.sh ~/nat/bootstrap.sh` and try again. (The bootstrap normally does this for you.)

**"Missing required modules"** in the UI
Open `pwsh` and run the `Install-Module` line from the Manual Install section above.

**Browser doesn't open automatically**
Open <http://localhost:5757> manually.

**"Awaiting Microsoft sign-in" hangs**
Look for a popup browser window behind your other windows. If you accidentally closed it, stop the server (Ctrl+C in the terminal) and run `start.cmd` again.

**Pre-existing partial offboarding**
The workflow detects users who are already partially offboarded (sign-in blocked, mailbox already shared, etc.) and surfaces a warning in the live log. The script will still run all 6 steps idempotently.
