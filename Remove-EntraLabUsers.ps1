<#
    Remove-EntraLabUsers.ps1

    Tears down an Entra lab created by New-EntraLabUsers.ps1: deletes the lab's
    department security groups (SG-* for the chosen company) and every user in
    the roster (data/users.json). Use this to reset between runs.

    Users are soft-deleted (recoverable for 30 days). Pass -PurgeDeleted to also
    permanently remove them from Deleted users.

    SAFETY: only deletes users listed in data/users.json and groups named SG-*
    for the selected company template. Review with -DryRun first.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo')]
    [string]$CompanyTemplate,

    # Permanently purge the soft-deleted users afterwards (irreversible).
    [switch]$PurgeDeleted,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

$rosterPath = Join-Path $PSScriptRoot 'data/users.json'
if (-not (Test-Path $rosterPath)) { Write-Error "No roster at $rosterPath - nothing to remove."; return }
$roster = Get-Content $rosterPath -Raw | ConvertFrom-Json
if ($CompanyTemplate -and $roster.company -ne $CompanyTemplate) {
    Write-Warning "Roster company is '$($roster.company)', not '$CompanyTemplate'. Continuing with the roster's company."
}
$template = Get-EntraCompanyTemplate -Key $roster.company

Write-Host "Tearing down '$($template.CompanyName)' - $($roster.people.Count) user(s) and their SG-* groups." -ForegroundColor Yellow
if ($DryRun) { Write-Host "==================== DRY RUN - nothing will be deleted ====================" -ForegroundColor Yellow }

if (-not $DryRun) { Connect-EntraLab | Out-Null }
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

# users
$deleted = 0
foreach ($p in $roster.people) {
    if ($DryRun) { Write-Host "  [DryRun] Would delete user $($p.upn)" -ForegroundColor DarkGray; continue }
    if (-not $PSCmdlet.ShouldProcess($p.upn, 'Delete user')) { continue }
    try {
        $id = $p.id
        if (-not $id) { $id = (Get-MgUser -Filter "userPrincipalName eq '$($p.upn)'" -ErrorAction Stop | Select-Object -First 1).Id }
        if ($id) { Remove-MgUser -UserId $id -ErrorAction Stop; $deleted++ }
    } catch { Write-Warning "Couldn't delete $($p.upn): $($_.Exception.Message)" }
}

# groups (SG-<DeptKey> + SG-AllEmployees)
$groupNames = @($template.Departments | ForEach-Object { "SG-$($_.Key)" }) + 'SG-AllEmployees'
$removedGroups = 0
foreach ($name in $groupNames) {
    if ($DryRun) { Write-Host "  [DryRun] Would delete group $name" -ForegroundColor DarkGray; continue }
    try {
        $g = Get-MgGroup -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) { if ($PSCmdlet.ShouldProcess($name, 'Delete group')) { Remove-MgGroup -GroupId $g.Id -ErrorAction Stop; $removedGroups++ } }
    } catch { Write-Warning "Couldn't delete group $name : $($_.Exception.Message)" }
}

# optional purge
if ($PurgeDeleted -and -not $DryRun) {
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    foreach ($p in $roster.people) {
        try {
            $d = Get-MgDirectoryDeletedItemAsUser -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $p.upn } | Select-Object -First 1
            if ($d -and $PSCmdlet.ShouldProcess($p.upn, 'Permanently purge')) { Remove-MgDirectoryDeletedItem -DirectoryObjectId $d.Id -ErrorAction Stop }
        } catch { Write-Warning "Couldn't purge $($p.upn): $($_.Exception.Message)" }
    }
}

if (-not $DryRun) {
    Remove-Item $rosterPath -ErrorAction SilentlyContinue
    Write-Host "Removed $deleted user(s) and $removedGroups group(s). Roster cleared." -ForegroundColor Green
    if (-not $PurgeDeleted) { Write-Host "Users are recoverable for 30 days (or re-run with -PurgeDeleted to purge)." -ForegroundColor DarkGray }
} else {
    Write-Host "Dry run complete." -ForegroundColor Yellow
}
