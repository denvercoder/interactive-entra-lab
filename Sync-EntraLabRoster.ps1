<#
    Sync-EntraLabRoster.ps1

    Rebuilds data/users.json from the users that already exist in your Entra
    tenant, by reading the members of the lab's SG-AllEmployees group. Use this
    to recover the roster the dashboard reads if data/users.json was lost or
    replaced (e.g. by a mock-mode run), without recreating any accounts.

    It does NOT create, modify, or delete anything in Entra - it only reads.

    Usage:
      pwsh ./Sync-EntraLabRoster.ps1 -TenantId yourtenant.onmicrosoft.com
      pwsh ./Sync-EntraLabRoster.ps1 -CompanyTemplate NimbusSoftwareSolutions -TenantId <guid>
#>

[CmdletBinding()]
param(
    [ValidateSet('NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo')]
    [string]$CompanyTemplate = 'NimbusSoftwareSolutions',

    [string]$TenantId,

    # The all-employees group the seeder created.
    [string]$GroupDisplayName = 'SG-AllEmployees'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

$DataDir    = Join-Path $PSScriptRoot 'data'
$RosterPath = Join-Path $DataDir 'users.json'
$ConfigPath = Join-Path $DataDir 'config.json'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$template = Get-EntraCompanyTemplate -Key $CompanyTemplate
$deptByName = @{}
foreach ($d in $template.Departments) { $deptByName[$d.DisplayName] = $d.Key }
$leadTitles = @{}
foreach ($d in $template.Departments) {
    foreach ($t in @($d.LeadTitle) + @($d.ExecTitles)) { if ($t) { $leadTitles[$t] = $true } }
}

Connect-EntraLab -TenantId $TenantId | Out-Null
Import-Module Microsoft.Graph.Users  -ErrorAction Stop
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

$domain = Get-EntraLabVerifiedDomain
Write-Host "Rebuilding roster for $($template.CompanyName) from '$GroupDisplayName' in $domain..." -ForegroundColor Cyan

$g = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'" -ErrorAction Stop | Select-Object -First 1
if (-not $g) { Write-Error "Group '$GroupDisplayName' not found - was the lab seeded in this tenant?"; return }

$members = Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop
$people = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($m in $members) {
    $i++
    Write-Progress -Activity "Reading users" -Status "$i of $($members.Count)" -PercentComplete ([math]::Min(100, [math]::Round(($i/[math]::Max(1,$members.Count))*100)))
    try {
        $u = Get-MgUser -UserId $m.Id -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,JobTitle,Department,OfficeLocation -ErrorAction Stop
    } catch { continue }
    if (-not $u.UserPrincipalName) { continue }

    $manager = $null
    try {
        $mgrRef = Get-MgUserManager -UserId $u.Id -ErrorAction SilentlyContinue
        if ($mgrRef) { $manager = (Get-MgUser -UserId $mgrRef.Id -Property DisplayName -ErrorAction SilentlyContinue).DisplayName }
    } catch {}

    $people.Add([pscustomobject]@{
        id          = $u.Id
        displayName = $u.DisplayName
        first       = $u.GivenName
        last        = $u.Surname
        upn         = $u.UserPrincipalName
        department  = $u.Department
        title       = $u.JobTitle
        office      = $u.OfficeLocation
        deptKey     = if ($u.Department -and $deptByName.ContainsKey($u.Department)) { $deptByName[$u.Department] } else { $null }
        isLead      = [bool]($u.JobTitle -and $leadTitles.ContainsKey($u.JobTitle))
        manager     = $manager
    })
}
Write-Progress -Activity "Reading users" -Completed

if ($people.Count -eq 0) { Write-Error "No users found in '$GroupDisplayName'."; return }

$roster = [pscustomobject]@{ company = $CompanyTemplate; domain = $domain; people = $people.ToArray() }
$roster | ConvertTo-Json -Depth 10 | Set-Content -Path $RosterPath -Encoding UTF8

$config = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ tier='Free'; mode='Mock'; nextTicketNumber=1001 } }
$config | Add-Member -NotePropertyName company -NotePropertyValue $CompanyTemplate -Force
$config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Host "Rebuilt roster with $($people.Count) user(s) -> $RosterPath" -ForegroundColor Green
Write-Host "Restart the dashboard (Live mode) and its tickets will reference these real accounts." -ForegroundColor Cyan
