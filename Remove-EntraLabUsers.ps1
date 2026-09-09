<#
    Remove-EntraLabUsers.ps1

    Tears down an Entra lab created by New-EntraLabUsers.ps1: deletes the lab's
    department security groups (SG-* for the chosen company) and its users. Use
    this to reset between runs.

    By default it deletes the users listed in the local roster (data/users.json).
    If that roster was lost or replaced, pass -FromTenant to enumerate the users
    to delete directly from the tenant's SG-AllEmployees group instead.

    Users are soft-deleted (recoverable for 30 days). Pass -PurgeDeleted to also
    permanently remove them from Deleted users.

    SAFETY: only deletes users in the roster (or SG-AllEmployees with -FromTenant)
    and groups named SG-* for the selected company. The signed-in account and every
    Global Administrator are ALWAYS protected and never deleted (add more with
    -ProtectUpns). Review with -DryRun first.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo')]
    [string]$CompanyTemplate,

    # Enumerate users to delete from the tenant (SG-AllEmployees) instead of the
    # local roster - use this when data/users.json is missing or out of date.
    [switch]$FromTenant,

    # Which Entra tenant to target (GUID or domain). Needed for personal Microsoft
    # accounts that are guests in a tenant.
    [string]$TenantId,

    # Permanently purge the soft-deleted users afterwards (irreversible).
    [switch]$PurgeDeleted,

    # Extra UPNs to never delete (on top of the always-protected accounts:
    # the signed-in user and every Global Administrator).
    [string[]]$ProtectUpns,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

$rosterPath   = Join-Path $PSScriptRoot 'data/users.json'
$artifactsPath = Join-Path $PSScriptRoot 'data/incident-artifacts.json'
$AllEmployeesGroup = 'SG-AllEmployees'

# --- figure out the company template and connect if we need the tenant ---
if ($FromTenant) {
    $key = if ($CompanyTemplate) { $CompanyTemplate } else { 'NimbusSoftwareSolutions' }
    $template = Get-EntraCompanyTemplate -Key $key
} else {
    if (-not (Test-Path $rosterPath)) { Write-Error "No roster at $rosterPath. Re-run with -FromTenant to enumerate from the tenant instead."; return }
    $roster = Get-Content $rosterPath -Raw | ConvertFrom-Json
    if ($CompanyTemplate -and $roster.company -ne $CompanyTemplate) {
        Write-Warning "Roster company is '$($roster.company)', not '$CompanyTemplate'. Continuing with the roster's company."
    }
    $template = Get-EntraCompanyTemplate -Key $roster.company
}

if ($DryRun) { Write-Host "==================== DRY RUN - nothing will be deleted ====================" -ForegroundColor Yellow }

# Connect if we're actually deleting, or if we must read the tenant to build the list.
if ((-not $DryRun) -or $FromTenant) { Connect-EntraLab -TenantId $TenantId | Out-Null }
Import-Module Microsoft.Graph.Users  -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

# --- protected accounts: NEVER delete the signed-in user, any Global Admin, or -ProtectUpns ---
$protectedIds  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$protectedUpns = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ((-not $DryRun) -or $FromTenant) {
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction SilentlyContinue
    # the account running this
    try {
        $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
        if ($me.id)  { [void]$protectedIds.Add([string]$me.id) }
        if ($me.userPrincipalName) { [void]$protectedUpns.Add([string]$me.userPrincipalName) }
    } catch {}
    # every Global Administrator
    try {
        $ga = Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq 'Global Administrator' } | Select-Object -First 1
        if ($ga) {
            foreach ($m in (Get-MgDirectoryRoleMember -DirectoryRoleId $ga.Id -All -ErrorAction Stop)) {
                if ($m.Id) { [void]$protectedIds.Add([string]$m.Id) }
            }
        }
    } catch { Write-Warning "Couldn't enumerate Global Administrators to protect them: $($_.Exception.Message)" }
    # explicit extras
    foreach ($upn in @($ProtectUpns)) {
        if (-not $upn) { continue }
        [void]$protectedUpns.Add($upn)
        try { $pu = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue | Select-Object -First 1; if ($pu) { [void]$protectedIds.Add([string]$pu.Id) } } catch {}
    }
    Write-Host "Protecting $($protectedIds.Count) account(s) from deletion (signed-in user + Global Admins$(if ($ProtectUpns) { ' + your -ProtectUpns' }))." -ForegroundColor DarkCyan
}

function Test-IsProtected {
    param([string]$Id, [string]$Upn)
    return ($Id -and $protectedIds.Contains($Id)) -or ($Upn -and $protectedUpns.Contains($Upn))
}

# --- build the list of users to remove ---
$people = @()
if ($FromTenant) {
    $g = Get-MgGroup -Filter "displayName eq '$AllEmployeesGroup'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) {
        foreach ($m in (Get-MgGroupMember -GroupId $g.Id -All -ErrorAction SilentlyContinue)) {
            $u = Get-MgUser -UserId $m.Id -Property Id,UserPrincipalName -ErrorAction SilentlyContinue
            if ($u) { $people += [pscustomobject]@{ id = $u.Id; upn = $u.UserPrincipalName } }
        }
    } else {
        Write-Warning "Group '$AllEmployeesGroup' not found (already torn down?). Falling back to companyName lookup."
    }
    # Fallback / belt-and-suspenders: also find lab users by the company name the
    # seeder stamps on each account (works even if the group was already deleted).
    if ($people.Count -eq 0) {
        try {
            $byCompany = Get-MgUser -All -ConsistencyLevel eventual -CountVariable null `
                -Filter "companyName eq '$($template.CompanyName)'" -Property Id,UserPrincipalName -ErrorAction Stop
            foreach ($u in $byCompany) { $people += [pscustomobject]@{ id = $u.Id; upn = $u.UserPrincipalName } }
        } catch { Write-Warning "companyName lookup failed ($($_.Exception.Message)); no users enumerated." }
    }
    if ($people.Count -eq 0) {
        Write-Host "No lab users found in the tenant - it looks already clean. Will still remove any leftover SG-* groups." -ForegroundColor Yellow
    } else {
        Write-Host "Tearing down '$($template.CompanyName)' - $($people.Count) user(s) and the SG-* groups." -ForegroundColor Yellow
    }
} else {
    $people = $roster.people
    Write-Host "Tearing down '$($template.CompanyName)' - $($people.Count) user(s) from the local roster and the SG-* groups." -ForegroundColor Yellow
}

# --- users ---
$deleted = 0; $protectedSkipped = 0
foreach ($p in $people) {
    if (Test-IsProtected -Id $p.id -Upn $p.upn) {
        Write-Host "  Protected (admin/self) - skipping $($p.upn)" -ForegroundColor DarkCyan; $protectedSkipped++; continue
    }
    if ($DryRun) { Write-Host "  [DryRun] Would delete user $($p.upn)" -ForegroundColor DarkGray; continue }
    if (-not $PSCmdlet.ShouldProcess($p.upn, 'Delete user')) { continue }
    try {
        $id = $p.id
        if (-not $id) { $id = (Get-MgUser -Filter "userPrincipalName eq '$($p.upn)'" -ErrorAction Stop | Select-Object -First 1).Id }
        if ($id -and (Test-IsProtected -Id $id -Upn $p.upn)) { Write-Host "  Protected - skipping $($p.upn)" -ForegroundColor DarkCyan; $protectedSkipped++; continue }
        if ($id) { Remove-MgUser -UserId $id -ErrorAction Stop; $deleted++ }
    } catch { Write-Warning "Couldn't delete $($p.upn): $($_.Exception.Message)" }
}

# --- groups (SG-<DeptKey> + SG-AllEmployees) ---
$groupNames = @($template.Departments | ForEach-Object { "SG-$($_.Key)" }) + $AllEmployeesGroup
$removedGroups = 0
foreach ($name in $groupNames) {
    if ($DryRun) { Write-Host "  [DryRun] Would delete group $name" -ForegroundColor DarkGray; continue }
    try {
        $g = Get-MgGroup -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { if ($PSCmdlet.ShouldProcess($name, 'Delete group')) { Remove-MgGroup -GroupId $g.Id -ErrorAction Stop; $removedGroups++ } }
    } catch { Write-Warning "Couldn't delete group $name : $($_.Exception.Message)" }
}

# --- incident artifacts (planted backdoor accounts + rogue role assignments) ---
if (Test-Path $artifactsPath) {
    $artifacts = @(Get-Content $artifactsPath -Raw | ConvertFrom-Json)
    foreach ($a in $artifacts) {
        if ($DryRun) { Write-Host "  [DryRun] Would clean up artifact: $($a.type) $($a.upn) $($a.roleName)" -ForegroundColor DarkGray; continue }
        try {
            switch ($a.type) {
                'user' {
                    $id = $a.userId
                    if (-not $id) { $id = (Get-MgUser -Filter "userPrincipalName eq '$($a.upn)'" -ErrorAction SilentlyContinue | Select-Object -First 1).Id }
                    if ($id) { Remove-MgUser -UserId $id -ErrorAction Stop; Write-Host "  Removed backdoor account $($a.upn)" -ForegroundColor DarkCyan }
                }
                'roleAssignment' {
                    Remove-EntraLabRoleAssignment -Upn $a.upn -RoleName $a.roleName | Out-Null
                    Write-Host "  Removed rogue '$($a.roleName)' assignment from $($a.upn)" -ForegroundColor DarkCyan
                }
            }
        } catch { Write-Warning "Couldn't clean up artifact ($($a.type) $($a.upn)): $($_.Exception.Message)" }
    }
    if (-not $DryRun) { Remove-Item $artifactsPath -ErrorAction SilentlyContinue }
}

# --- optional permanent purge ---
if ($PurgeDeleted -and -not $DryRun) {
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    foreach ($p in $people) {
        if (Test-IsProtected -Id $p.id -Upn $p.upn) { continue }
        try {
            $d = Get-MgDirectoryDeletedItemAsUser -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $p.upn } | Select-Object -First 1
            if ($d -and $PSCmdlet.ShouldProcess($p.upn, 'Permanently purge')) { Remove-MgDirectoryDeletedItem -DirectoryObjectId $d.Id -ErrorAction Stop }
        } catch { Write-Warning "Couldn't purge $($p.upn): $($_.Exception.Message)" }
    }
}

if (-not $DryRun) {
    Remove-Item $rosterPath -ErrorAction SilentlyContinue
    Write-Host "Removed $deleted user(s) and $removedGroups group(s). Local roster cleared." -ForegroundColor Green
    if ($protectedSkipped -gt 0) { Write-Host "Protected $protectedSkipped account(s) (admin/self) - left untouched." -ForegroundColor DarkCyan }
    if (-not $PurgeDeleted) { Write-Host "Users are recoverable for 30 days (or re-run with -PurgeDeleted to purge)." -ForegroundColor DarkGray }
} else {
    if ($protectedSkipped -gt 0) { Write-Host "(Would protect $protectedSkipped admin/self account(s).)" -ForegroundColor DarkCyan }
    Write-Host "Dry run complete." -ForegroundColor Yellow
}
