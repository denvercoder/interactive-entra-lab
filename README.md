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
- **Tickets vs Alerts** — user-submitted issues land in the main ticket queue;
  automated security signals (SIEM / Identity Protection style) are routed to a
  separate **Alerts** view behind the 🔔 bell in the header (with an unread
  badge), because those wouldn't arrive as help-desk tickets in real life.
- **Verify fix** — actionable tickets have a *Re-check tenant state* button that
  confirms the fix (account re-enabled, user restored, back in the group, role
  removed, backdoor deleted). Live mode queries Graph; Mock simulates it.

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
| `Update-OfflineIdentityCache.ps1` | Fetches 1,000 identities from Mockaroo once into `offline-identities.json`, so `-Offline` gets Mockaroo-quality data with no key/internet. |
| `EntraLabHelpers.ps1` | Pure logic: company templates, offline identities, allocation math, password/nickname generation, and the **incident catalog**. Dot-sourced; not run directly. |
| `EntraLabGraph.ps1` | The Microsoft Graph layer: sign-in and the real incident actions. Dot-sourced. |
| `incidents/Invoke-EntraIncident.ps1` | Run a single incident from the command line (supports `-WhatIf`). |
| `dashboard/Start-Dashboard.ps1` | The local web server (built on .NET `HttpListener`) + ticket API. |
| `dashboard/public/` | The dashboard UI (`index.html`, `app.js`, `styles.css`). |
| `EntraLabHelpers.Tests.ps1` | Pester tests for the pure logic. Run with `Invoke-Pester`. |
| `offline-identities.json` | Optional cached Mockaroo pull (created by `Update-OfflineIdentityCache.ps1`) that `-Offline` samples from. Fake data, safe to commit. |
| `data/` | Runtime state: `config.json`, `tickets.json`, `users.json`, `incident-artifacts.json`, credential CSVs. Gitignored; safe to delete to reset. |

---

## `New-EntraLabUsers.ps1` parameters

| Parameter | Replaces the prompt for… |
|---|---|
| `-UserCount <1-1000>` | "How many users do you want?" |
| `-UseRandomPasswords` / `-SharedPassword <pw>` | "Would you like random passwords?" |
| `-CompanyTemplate <name>` | Which fictitious company (Nimbus / Summit / Harbor). |
| `-TenantId <guid or domain>` | Which Entra tenant to sign into. **Required if you sign in with a personal Microsoft account** that's a guest/member of a tenant (otherwise Graph gives an MSA context and directory calls fail). |
| `-Offline` | Use local identities instead of calling Mockaroo (prefers `offline-identities.json` if present, else the built-in name lists). |
| `-MockarooApiKey <key>` | Your Mockaroo key (or set `$MockarooApiKeyDefault` in the script). |
| `-UsageLocation <cc>` | Two-letter usage location for the accounts (default `US`). |
| `-Seed <int>` | Make a run reproducible (combine with `-Offline`). |
| `-DryRun` | Preview the whole plan with zero writes to Entra. |

### Offline identity cache

By default `-Offline` uses built-in name lists. For richer, Mockaroo-quality
offline data, build the cache once:

```powershell
./Update-OfflineIdentityCache.ps1        # prompts for your Mockaroo key, fetches 1,000
```

That writes `offline-identities.json`; from then on every `-Offline` run samples
from it (no key or internet needed), and the file is safe to commit so it works
for anyone who clones the repo.

### Signing into the right tenant

If your `Connect-MgGraph` sign-in lands on a **personal Microsoft account**, you'll
see *"This API is not supported for MSA accounts."* Pass your tenant explicitly:

```powershell
./New-EntraLabUsers.ps1 -TenantId yourtenant.onmicrosoft.com   # or the tenant GUID
```

Find your tenant's primary domain / ID at <https://entra.microsoft.com> → Overview.

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
| **Rogue admin** | Free | **Adds a standard user to a privileged role** | Find + remove the role assignment |
| **Backdoor account** | Free | **Creates a planted `svc-*` account** with a weak password | Verify + delete it |
| **MFA tampering** | Free | **Clears the user's MFA methods** | Re-register MFA, secure the account |
| Failed-login burst | Free | Synthetic alert (odd-hours brute force) | Triage; reset/revoke if compromised |
| Impossible travel | Free | Synthetic alert | Triage; confirm with the user |
| MFA fatigue | Free | Synthetic alert (prompt bombing) | Triage; reset/revoke |
| MFA reset | Paid | Clears the user's Authenticator/phone methods | Re-register MFA |
| Risky sign-in / CA block | Paid | Review scenario | Dismiss/confirm; grant a compliant path |
| **Privilege escalation (audited)** | Paid | Rogue role grant **+ reads the real audit-log entry** | Remove role; cross-check the audit event |
| **Risky users report** | Paid | **Queries live Identity Protection risky users** | Investigate + dismiss/remediate each |
| **Sign-in anomaly review** | Paid | **Queries live sign-in logs** for off-hours/failed | Triage the real sign-ins |

### Simulating attacker activity

The lab can simulate real adversary behaviour, split by the **Free/Paid** toggle:

- **Free** — attacker *actions* that make genuine, findable changes to the
  directory (rogue admin, backdoor account, MFA tampering), plus synthetic
  security *alerts* for triage practice (odd-hours failed logins, impossible
  travel, MFA fatigue).
- **Paid** — everything Free, **plus** incidents that query **real P1/P2 data**:
  the directory audit log, Identity Protection risky users, and sign-in logs.

Why the split? On a free tenant you **cannot read** sign-in logs, audit logs, or
risky users via Graph (they require Entra ID P1/P2), and generating real sign-ins
is blocked by security defaults. So on free those are illustrative; on a P1/P2
tenant the Paid incidents pull the real thing. If a Paid read is attempted on a
tenant without the license, the ticket says so instead of failing.

- The rogue-admin role defaults to **User Administrator** (privileged but
  reversible). Override with `Start-Dashboard.ps1 -SecurityRole 'Global Administrator'`
  for the classic scenario — be careful in a shared tenant.
- Backdoor accounts and rogue role grants are recorded in
  `data/incident-artifacts.json`, and `Remove-EntraLabUsers.ps1` cleans them up
  along with the roster.

> The old free-tier "risky sign-in" / "Conditional Access block" tickets remain
> as Paid review scenarios; they can't be synthetically generated via Graph.

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
