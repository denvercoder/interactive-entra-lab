<#
    Add-EntraLabDevices.ps1

    Adds synthetic Entra device objects to the lab and assigns each to one of the
    seeded users as its registered owner, then records them in data/devices.json
    (which the dashboard reads for the device incidents in Live mode).

    These are cloud-only directory device objects - NOT real registered machines -
    created only so device incidents (disabled device, stale device) have
    something to act on. Run it AFTER New-EntraLabUsers.ps1.

    Some tenants restrict manual/delegated device creation; if a create fails the
    script keeps going and reports how many succeeded, so it never leaves a
    half-broken state.

    Usage:
      pwsh ./Add-EntraLabDevices.ps1 -TenantId yourtenant.onmicrosoft.com
      pwsh ./Add-EntraLabDevices.ps1 -TenantId <guid> -Coverage 0.6 -DryRun
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    # Fraction of users that get at least one device (0-1).
    [ValidateRange(0,1)][double]$Coverage = 0.6,

    # Chance a covered user gets a second device.
    [ValidateRange(0,1)][double]$SecondDeviceChance = 0.2,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

$DataDir     = Join-Path $PSScriptRoot 'data'
$RosterPath  = Join-Path $DataDir 'users.json'
$DevicesPath = Join-Path $DataDir 'devices.json'

if (-not (Test-Path $RosterPath)) { Write-Error "No roster at $RosterPath. Run New-EntraLabUsers.ps1 first."; return }
$roster = Get-Content $RosterPath -Raw | ConvertFrom-Json
$people = @($roster.people)
if ($people.Count -eq 0) { Write-Error "Roster is empty."; return }

if ($DryRun) { Write-Host "==================== DRY RUN - no devices will be created ====================" -ForegroundColor Yellow }
if (-not $DryRun) { Connect-EntraLab -TenantId $TenantId | Out-Null }

$devices = [System.Collections.Generic.List[object]]::new()
$made = 0; $failed = 0
foreach ($u in $people) {
    if ((Get-Random -Minimum 0.0 -Maximum 1.0) -gt $Coverage) { continue }
    $count = 1
    if ((Get-Random -Minimum 0.0 -Maximum 1.0) -le $SecondDeviceChance) { $count = 2 }
    for ($i = 0; $i -lt $count; $i++) {
        $os = Get-Random -InputObject $script:DeviceOSes
        $name = New-LabDeviceName -First $u.first -Last $u.last -OS $os
        if ($DryRun) {
            Write-Host "  [DryRun] Would create $name ($os) owned by $($u.upn)" -ForegroundColor DarkGray
            $devices.Add([pscustomobject]@{ id = $null; displayName = $name; os = $os; enabled = $true; ownerUpn = $u.upn; ownerName = $u.displayName; ownerId = $u.id })
            continue
        }
        try {
            $rec = New-EntraLabDevice -DisplayName $name -OperatingSystem $os -OwnerId $u.id -OwnerUpn $u.upn -OwnerName $u.displayName
            $devices.Add($rec); $made++
            Write-Progress -Activity "Creating devices" -Status "$name ($made)"
        } catch {
            $failed++
            Write-Warning "Failed to create device $name : $($_.Exception.Message)"
            if ($failed -ge 3 -and $made -eq 0) {
                Write-Error "The first several device creations all failed - this tenant likely blocks delegated device creation. Stopping. (Users/groups are unaffected.)"
                return
            }
        }
    }
}
Write-Progress -Activity "Creating devices" -Completed

if ($devices.Count -eq 0 -and -not $DryRun) { Write-Error "No devices were created."; return }

$out = [pscustomobject]@{ company = $roster.company; devices = $devices.ToArray() }
if (-not $DryRun) {
    $out | ConvertTo-Json -Depth 8 | Set-Content -Path $DevicesPath -Encoding UTF8
    Write-Host ""
    Write-Host "Created $made device(s)$(if ($failed) { " ($failed failed)" }) across $((@($devices | Select-Object -ExpandProperty ownerUpn -Unique)).Count) user(s)." -ForegroundColor Green
    Write-Host "Recorded to $DevicesPath - the dashboard's device incidents will use these in Live mode." -ForegroundColor Cyan
} else {
    Write-Host "Dry run complete - would have created $($devices.Count) device(s)." -ForegroundColor Yellow
}
