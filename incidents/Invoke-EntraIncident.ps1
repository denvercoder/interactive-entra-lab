<#
    Invoke-EntraIncident.ps1

    Runs a single lab incident from the command line - the same actions the
    dashboard performs in Live mode, but scriptable and standalone. Useful for
    testing an action, or for scripting a classroom scenario without the UI.

    It reads the roster written by New-EntraLabUsers.ps1 (data/users.json),
    picks a random affected user (or one you name), performs the action against
    Entra, and prints a ticket-style summary.

    Examples:
      pwsh ./incidents/Invoke-EntraIncident.ps1 -Action DisableUser
      pwsh ./incidents/Invoke-EntraIncident.ps1 -Action DeleteUser -Upn jdoe@contoso.onmicrosoft.com
      pwsh ./incidents/Invoke-EntraIncident.ps1 -Action ForcePasswordReset -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DisableUser','EnableUser','ForcePasswordReset','DeleteUser','RestoreUser','RemoveGroupMember','ResetMfa')]
    [string]$Action,

    # Target a specific user by UPN. Omit to pick a random user from the roster.
    [string]$Upn,

    # For RemoveGroupMember: the group to remove them from (defaults to their SG-<Dept>).
    [string]$GroupDisplayName
)

$ErrorActionPreference = 'Stop'
$LabRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $LabRoot 'EntraLabHelpers.ps1')
. (Join-Path $LabRoot 'EntraLabGraph.ps1')

$rosterPath = Join-Path $LabRoot 'data/users.json'
if (-not (Test-Path $rosterPath)) {
    Write-Error "No roster found at $rosterPath. Run New-EntraLabUsers.ps1 first."; return
}
$roster = Get-Content $rosterPath -Raw | ConvertFrom-Json

# Resolve the target person.
if ($Upn) {
    $person = $roster.people | Where-Object { $_.upn -eq $Upn } | Select-Object -First 1
    if (-not $person) { Write-Warning "UPN $Upn not in roster; will act on it directly anyway." }
} else {
    $person = $roster.people | Get-Random
    $Upn = $person.upn
}
Write-Host "Incident: $Action  ->  $Upn" -ForegroundColor Cyan

Connect-EntraLab | Out-Null

if (-not $PSCmdlet.ShouldProcess($Upn, $Action)) { return }

$detail = switch ($Action) {
    'DisableUser'        { Invoke-EntraLabDisableUser -Upn $Upn }
    'EnableUser'         { Invoke-EntraLabEnableUser -Upn $Upn }
    'ForcePasswordReset' { Invoke-EntraLabForcePasswordReset -Upn $Upn }
    'DeleteUser'         { Invoke-EntraLabDeleteUser -Upn $Upn }
    'RestoreUser'        { Invoke-EntraLabRestoreUser -Upn $Upn }
    'ResetMfa'           { Invoke-EntraLabResetMfa -Upn $Upn }
    'RemoveGroupMember'  {
        $grp = if ($GroupDisplayName) { $GroupDisplayName } elseif ($person -and $person.deptKey) { "SG-$($person.deptKey)" } else { 'SG-AllEmployees' }
        Invoke-EntraLabRemoveGroupMember -Upn $Upn -GroupDisplayName $grp
    }
}

Write-Host $detail -ForegroundColor Green
