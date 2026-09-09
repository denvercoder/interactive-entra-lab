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
    and groups named SG-* for the selected company. Review with -DryRun first.
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

# --- build the list of users to remove ---
$people = @()
if ($FromTenant) {
    $g = Get-MgGroup -Filter "displayName eq '$AllEmployeesGroup'" -ErrorAction Stop | Select-Object -First 1
    if (-not $g) { Write-Error "Group '$AllEmployeesGroup' not found in the tenant - nothing to enumerate."; return }
    $members = Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop
    foreach ($m in $members) {
        $u = Get-MgUser -UserId $m.Id -Property Id,UserPrincipalName -ErrorAction SilentlyContinue
        if ($u) { $people += [pscustomobject]@{ id = $u.Id; upn = $u.UserPrincipalName } }
    }
    Write-Host "Tearing down '$($template.CompanyName)' - $($people.Count) user(s) from $AllEmployeesGroup and the SG-* groups." -ForegroundColor Yellow
} else {
    $people = $roster.people
    Write-Host "Tearing down '$($template.CompanyName)' - $($people.Count) user(s) from the local roster and the SG-* groups." -ForegroundColor Yellow
}

# --- users ---
$deleted = 0
foreach ($p in $people) {
    if ($DryRun) { Write-Host "  [DryRun] Would delete user $($p.upn)" -ForegroundColor DarkGray; continue }
    if (-not $PSCmdlet.ShouldProcess($p.upn, 'Delete user')) { continue }
    try {
        $id = $p.id
        if (-not $id) { $id = (Get-MgUser -Filter "userPrincipalName eq '$($p.upn)'" -ErrorAction Stop | Select-Object -First 1).Id }
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
        try {
            $d = Get-MgDirectoryDeletedItemAsUser -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $p.upn } | Select-Object -First 1
            if ($d -and $PSCmdlet.ShouldProcess($p.upn, 'Permanently purge')) { Remove-MgDirectoryDeletedItem -DirectoryObjectId $d.Id -ErrorAction Stop }
        } catch { Write-Warning "Couldn't purge $($p.upn): $($_.Exception.Message)" }
    }
}

if (-not $DryRun) {
    Remove-Item $rosterPath -ErrorAction SilentlyContinue
    Write-Host "Removed $deleted user(s) and $removedGroups group(s). Local roster cleared." -ForegroundColor Green
    if (-not $PurgeDeleted) { Write-Host "Users are recoverable for 30 days (or re-run with -PurgeDeleted to purge)." -ForegroundColor DarkGray }
} else {
    Write-Host "Dry run complete." -ForegroundColor Yellow
}
