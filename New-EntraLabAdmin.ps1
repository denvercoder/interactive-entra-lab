<#
    New-EntraLabAdmin.ps1

    Creates a native cloud Global Administrator in the tenant (e.g.
    admin@yourtenant.onmicrosoft.com) with a strong temporary password. Useful
    when the tenant's only admin is a personal Microsoft account added as a guest
    (#EXT#), which can't always complete billing / trial signups. Sign in as this
    native admin to start the Entra ID P2 trial and manage the tenant.

    It reads only what it needs and creates one user + one role assignment.

    Usage:
      pwsh ./New-EntraLabAdmin.ps1 -TenantId yourtenant.onmicrosoft.com
      pwsh ./New-EntraLabAdmin.ps1 -TenantId <guid> -UserPrincipalName admin@yourtenant.onmicrosoft.com
#>

[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$DisplayName  = 'Tenant Admin',
    [string]$MailNickname = 'admin',
    # Defaults to <MailNickname>@<tenant default domain>.
    [string]$UserPrincipalName,
    [string]$UsageLocation = 'US'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

Connect-EntraLab -TenantId $TenantId | Out-Null
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop

$domain = Get-EntraLabVerifiedDomain
if (-not $UserPrincipalName) { $UserPrincipalName = "$MailNickname@$domain" }

$existing = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue | Select-Object -First 1
$tempPassword = $null
if ($existing) {
    Write-Warning "User $UserPrincipalName already exists - will just ensure the Global Administrator role."
    $u = $existing
} else {
    $tempPassword = New-RandomPassword
    $u = New-MgUser -DisplayName $DisplayName -MailNickname $MailNickname -UserPrincipalName $UserPrincipalName `
            -AccountEnabled -UsageLocation $UsageLocation `
            -PasswordProfile @{ Password = $tempPassword; ForceChangePasswordNextSignIn = $true } -ErrorAction Stop
    Write-Host "Created $UserPrincipalName" -ForegroundColor Green
}

$role = Get-EntraLabDirectoryRole -RoleName 'Global Administrator'
$already = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq $u.Id }
if ($already) {
    Write-Host "$UserPrincipalName already holds Global Administrator." -ForegroundColor DarkGray
} else {
    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($u.Id)" } -ErrorAction Stop
    Write-Host "Granted Global Administrator to $UserPrincipalName." -ForegroundColor Green
}

Write-Host ""
Write-Host "Sign-in name: $UserPrincipalName" -ForegroundColor Cyan
if ($tempPassword) {
    Write-Host "Temp password: $tempPassword" -ForegroundColor Yellow
    Write-Host "(You'll be asked to change it at first sign-in.)" -ForegroundColor DarkGray
}
Write-Host "Sign in at https://entra.microsoft.com as this account, then start the Entra ID P2 trial." -ForegroundColor Cyan
