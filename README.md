# Interactive Entra Lab

An interactive Microsoft Entra ID (Azure AD) training lab with two parts:

1. **A user-seeding script** (`New-EntraLabUsers.ps1`) that builds a realistic
   company in your Entra tenant — departments, security groups, employees with
   titles and a manager hierarchy — using the same fictitious companies and the
   same interactive prompts as the companion [Active Directory lab](../).
2. **A web-based help-desk dashboard** that turns the tenant into a training
   ground: click **Check for new tickets** and the lab runs real incidents
   against real accounts (locks someone out, resets a password, "accidentally"
   deletes an account, drops someone from a group) and files a support ticket
   written in that employee's voice. You work the ticket through
   **Open → In Progress → Resolved → Closed**, documenting what you did.

Everything runs **locally** on **PowerShell 7** — no Node, no Python, no
database, no hosting. Works the same on Windows, macOS, and Linux.

---

## What it looks like

The dashboard brands itself as whichever fictitious company you seeded and reads
like a real IT service desk: prioritized ticket queue, requester details, a
"behind the scenes" panel explaining what the incident did to the account, and a
required write-up when you close a ticket.

- **Free / Paid toggle** — Free shows incidents that work on Entra ID Free
  (lockouts, password resets, deletes, group access, new-hire provisioning).
  Paid adds P1/P2-flavored incidents (risky sign-in, Conditional Access block,
  MFA reset).
- **Mock / Live toggle** — **Mock** needs no tenant at all: it fabricates a
  believable employee roster and only *simulates* the actions, so you can demo
  the whole flow immediately. **Live** performs the real Graph actions against
  the accounts you seeded.

---

## Requirements

- **PowerShell 7+** (`pwsh`). [Install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell).
- For **Live mode / seeding**: the **Microsoft Graph PowerShell SDK** —
  ```powershell
  Install-Module Microsoft.Graph -Scope CurrentUser
  ```
  and an Entra tenant with an account that can create users and groups
  (User Administrator + Groups Administrator, or Global Administrator). A **free
  Entra ID tenant** is fine.
- For realistic names/addresses when seeding: a free
  [Mockaroo](https://www.mockaroo.com) API key — **or** pass `-Offline` to
  generate identities locally.
- **Mock mode needs none of the above** — just PowerShell 7 and a browser.

---

## Quick start

### 1. Try the dashboard right now (Mock mode, no tenant)

```bash
pwsh ./dashboard/Start-Dashboard.ps1
```

Open <http://localhost:8080>, click **Check for new tickets**, and work a few
tickets through to Closed. Switch companies and the Free/Paid toggle from the
header.

### 2. Seed a real tenant

```powershell
# Interactive — you'll be prompted for count and password mode, then a browser sign-in.
./New-EntraLabUsers.ps1 -CompanyTemplate NimbusSoftwareSolutions

# Or fully non-interactive, offline identities, preview only:
./New-EntraLabUsers.ps1 -CompanyTemplate SummitRetailGroup -UserCount 40 -UseRandomPasswords -Offline -DryRun
```

This creates the users and groups, writes plaintext credentials to
`data/EntraLabUsers_<timestamp>.csv` (lab use only), and records the roster in
`data/users.json` and the company in `data/config.json`.

### 3. Run the dashboard in Live mode

```bash
pwsh ./dashboard/Start-Dashboard.ps1 -Mode Live
```

Now **Check for new tickets** performs real actions against the seeded accounts.
The first live action opens a browser for Graph sign-in.

### 4. Tear it all down

```powershell
./Remove-EntraLabUsers.ps1            # soft-delete the roster's users + SG-* groups
./Remove-EntraLabUsers.ps1 -PurgeDeleted   # also purge them permanently
./Remove-EntraLabUsers.ps1 -DryRun    # preview first
```

---

## Files

| File | Purpose |
|---|---|
| `New-EntraLabUsers.ps1` | Seeds the tenant (users, groups, hierarchy). Same prompts as the AD lab. |
| `Remove-EntraLabUsers.ps1` | Tears the lab down (soft-delete, optional purge). |
| `EntraLabHelpers.ps1` | Pure logic: company templates, offline identities, allocation math, password/nickname generation, and the **incident catalog**. Dot-sourced; not run directly. |
| `EntraLabGraph.ps1` | The Microsoft Graph layer: sign-in and the real incident actions. Dot-sourced. |
| `incidents/Invoke-EntraIncident.ps1` | Run a single incident from the command line (supports `-WhatIf`). |
| `dashboard/Start-Dashboard.ps1` | The local web server (built on .NET `HttpListener`) + ticket API. |
| `dashboard/public/` | The dashboard UI (`index.html`, `app.js`, `styles.css`). |
| `EntraLabHelpers.Tests.ps1` | Pester tests for the pure logic. Run with `Invoke-Pester`. |
| `data/` | Runtime state: `config.json`, `tickets.json`, `users.json`, credential CSVs. Safe to delete to reset. |

---

## `New-EntraLabUsers.ps1` parameters

| Parameter | Replaces the prompt for… |
|---|---|
| `-UserCount <1-1000>` | "How many users do you want?" |
| `-UseRandomPasswords` / `-SharedPassword <pw>` | "Would you like random passwords?" |
| `-CompanyTemplate <name>` | Which fictitious company (Nimbus / Summit / Harbor). |
| `-Offline` | Generate identities locally instead of calling Mockaroo. |
| `-MockarooApiKey <key>` | Your Mockaroo key (or set `$MockarooApiKeyDefault` in the script). |
| `-UsageLocation <cc>` | Two-letter usage location for the accounts (default `US`). |
| `-Seed <int>` | Make a run reproducible (combine with `-Offline`). |
| `-DryRun` | Preview the whole plan with zero writes to Entra. |

---

## The incident catalog

Incidents live in `Get-EntraIncidentCatalog` in `EntraLabHelpers.ps1`. Each entry
defines the ticket text (in an employee's voice), a priority, a tier (Free/Paid),
the action the engine performs, and a suggested fix. Add your own by appending to
that list — the dashboard picks them up automatically.

| Incident | Tier | What the engine does | How you fix it |
|---|---|---|---|
| Locked out / disabled | Free | Sets `accountEnabled = false` | Re-enable the account |
| Forgot password | Free | Resets to a password the "user" doesn't know | Reset to a temp password |
| Account deleted | Free | Soft-deletes the user | Restore from Deleted users |
| Lost group access | Free | Removes the user from their `SG-<Dept>` group | Re-add them |
| New hire | Free | (no action) provisioning request | Create the account |
| Name change | Free | (no action) request | Update surname/display name |
| Risky sign-in | Paid | Scenario for Identity Protection review | Dismiss/confirm the risk |
| Conditional Access block | Paid | Scenario for CA sign-in review | Grant a compliant path |
| MFA reset | Paid | Clears the user's Authenticator/phone methods | Re-register MFA |

> Risky sign-in and Conditional Access can't be *synthetically generated* through
> Graph, so in Live mode those tickets are filed as review scenarios rather than
> pre-triggered state.

---

## Safety notes

- Point this only at a **lab/training tenant**. The scripts create and delete
  **real** objects. Use `-DryRun` to preview.
- Deleted users are **soft-deleted** (recoverable for 30 days) unless you pass
  `-PurgeDeleted`.
- Credential CSVs contain **plaintext passwords** for the lab accounts — treat
  them accordingly and delete them when done.
- `Remove-EntraLabUsers.ps1` only touches users listed in `data/users.json` and
  groups named `SG-*` for the selected company.
