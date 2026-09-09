<#
    EntraLabGraph.ps1

    The Microsoft Graph layer for the Interactive Entra Lab: connecting (via
    interactive sign-in), resolving the tenant's verified domain, and the actual
    incident actions the ticket system performs against real Entra accounts
    (disable, reset password, delete, restore, remove-from-group, reset MFA,
    provision a new hire).

    Dot-sourced by New-EntraLabUsers.ps1, Remove-EntraLabUsers.ps1,
    incidents/Invoke-EntraIncident.ps1, and the dashboard's Live mode.

    Everything here talks to Graph, so - unlike EntraLabHelpers.ps1 - it is NOT
    side-effect free. It uses the Microsoft.Graph PowerShell SDK.

    Required modules (install once):
        Install-Module Microsoft.Graph.Authentication,
                       Microsoft.Graph.Users,
                       Microsoft.Graph.Groups,
                       Microsoft.Graph.Identity.DirectoryManagement,
                       Microsoft.Graph.Identity.SignIns -Scope CurrentUser
    (or simply: Install-Module Microsoft.Graph -Scope CurrentUser)
#>

# Delegated scopes we ask for at sign-in. Kept to the minimum the lab needs.
$script:EntraLabScopes = @(
    'User.ReadWrite.All'                 # create / update / disable / delete users
    'Group.ReadWrite.All'                # department group membership
    'Directory.ReadWrite.All'            # restore soft-deleted users, read domains
    'UserAuthenticationMethod.ReadWrite.All'  # reset MFA methods (Paid incidents)
)

function Test-EntraLabModules {
    <# Warn early and clearly if the Graph SDK isn't installed. #>
    $needed = 'Microsoft.Graph.Authentication','Microsoft.Graph.Users','Microsoft.Graph.Groups','Microsoft.Graph.Identity.DirectoryManagement'
    $missing = $needed | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missing) {
        throw "Missing required module(s): $($missing -join ', '). Install with:  Install-Module Microsoft.Graph -Scope CurrentUser"
    }
}

function Connect-EntraLab {
    <#
        Interactive sign-in. Safe to call repeatedly - if there's already a
        context with the scopes we need, it's a no-op. Pass -Force to reconnect.

        -TenantId targets a specific Entra tenant (GUID or a domain like
        contoso.onmicrosoft.com). REQUIRED when your sign-in account is a
        personal Microsoft account (MSA) that is a guest/member of an Entra
        tenant - without it Graph gives you an MSA context where directory APIs
        (domains, user/group creation) fail with "not supported for MSA accounts".
    #>
    param([switch]$Force, [string]$TenantId)

    Test-EntraLabModules
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = $null
    try { $ctx = Get-MgContext } catch { $ctx = $null }

    $haveScopes = $ctx -and (@($script:EntraLabScopes | Where-Object { $_ -notin @($ctx.Scopes) }).Count -eq 0)
    $tenantOk   = (-not $TenantId) -or ($ctx -and ($ctx.TenantId -eq $TenantId))
    if ($ctx -and $haveScopes -and $tenantOk -and -not $Force) {
        Write-Verbose "Already connected to Graph as $($ctx.Account)."
        return $ctx
    }

    Write-Host "Signing in to Microsoft Graph (a browser window will open)..." -ForegroundColor Cyan
    $connectParams = @{ Scopes = $script:EntraLabScopes; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams.TenantId = $TenantId; Write-Host "  Target tenant: $TenantId" -ForegroundColor DarkGray }
    Connect-MgGraph @connectParams
    return Get-MgContext
}

function Get-EntraLabVerifiedDomain {
    <# The default verified domain for building UPNs (e.g. contoso.onmicrosoft.com). #>
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    try {
        $domains = Get-MgDomain -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -match 'MSA accounts') {
            $acct = try { (Get-MgContext).Account } catch { 'your account' }
            throw "Signed in as a personal Microsoft account ($acct) with no Entra directory context. Re-run and pass -TenantId <your-tenant>.onmicrosoft.com (or the tenant GUID) so it signs into your Entra tenant. Find it at https://entra.microsoft.com > Overview. If you don't have a tenant yet, create a free one (e.g. the Microsoft 365 Developer Program) first."
        }
        throw
    }
    $default = $domains | Where-Object { $_.IsDefault } | Select-Object -First 1
    if (-not $default) { $default = $domains | Where-Object { $_.IsInitial } | Select-Object -First 1 }
    if (-not $default) { $default = $domains | Select-Object -First 1 }
    if (-not $default) { throw "Couldn't determine a verified domain for this tenant." }
    return $default.Id
}

# =============================== INCIDENT ACTIONS ============================
# Each returns a short human-readable detail string describing what it did, and
# throws on hard failure. They operate on a real Entra user resolved by UPN so
# they stay correct even if the local roster drifted.

function Resolve-EntraLabUser {
    param([Parameter(Mandatory)][string]$Upn)
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    $u = Get-MgUser -Filter "userPrincipalName eq '$Upn'" -Property Id,DisplayName,UserPrincipalName,AccountEnabled,Department -ErrorAction Stop | Select-Object -First 1
    if (-not $u) { throw "User $Upn not found in the tenant." }
    return $u
}

function Invoke-EntraLabDisableUser {
    param([Parameter(Mandatory)][string]$Upn)
    $u = Resolve-EntraLabUser -Upn $Upn
    Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop
    return "Disabled $($u.DisplayName) ($Upn) - accountEnabled set to false."
}

function Invoke-EntraLabEnableUser {
    param([Parameter(Mandatory)][string]$Upn)
    $u = Resolve-EntraLabUser -Upn $Upn
    Update-MgUser -UserId $u.Id -AccountEnabled:$true -ErrorAction Stop
    return "Re-enabled $($u.DisplayName) ($Upn)."
}

function Invoke-EntraLabForcePasswordReset {
    param([Parameter(Mandatory)][string]$Upn)
    $u = Resolve-EntraLabUser -Upn $Upn
    # Set a throwaway temp password the "user" no longer knows - simulating a
    # forgotten password. The technician resets it again as the fix.
    $temp = New-RandomPassword
    $pwProfile = @{ Password = $temp; ForceChangePasswordNextSignIn = $true }
    Update-MgUser -UserId $u.Id -PasswordProfile $pwProfile -ErrorAction Stop
    return "Reset $($u.DisplayName)'s password to a value they don't know (forces the 'forgot password' scenario)."
}

function Invoke-EntraLabDeleteUser {
    param([Parameter(Mandatory)][string]$Upn)
    $u = Resolve-EntraLabUser -Upn $Upn
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    Remove-MgUser -UserId $u.Id -ErrorAction Stop
    return "Soft-deleted $($u.DisplayName) ($Upn). Recoverable from Deleted users for 30 days (Restore-MgDirectoryDeletedItem -DirectoryObjectId $($u.Id))."
}

function Invoke-EntraLabRestoreUser {
    param([Parameter(Mandatory)][string]$Upn)
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    $deleted = Get-MgDirectoryDeletedItemAsUser -ErrorAction Stop | Where-Object { $_.UserPrincipalName -eq $Upn } | Select-Object -First 1
    if (-not $deleted) { throw "No soft-deleted user found for $Upn (already restored, or older than 30 days)." }
    Restore-MgDirectoryDeletedItem -DirectoryObjectId $deleted.Id -ErrorAction Stop | Out-Null
    return "Restored $Upn from Deleted users."
}

function Invoke-EntraLabRemoveGroupMember {
    param([Parameter(Mandatory)][string]$Upn, [Parameter(Mandatory)][string]$GroupDisplayName)
    Import-Module Microsoft.Graph.Groups -ErrorAction Stop
    $u = Resolve-EntraLabUser -Upn $Upn
    $g = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'" -ErrorAction Stop | Select-Object -First 1
    if (-not $g) { throw "Group '$GroupDisplayName' not found." }
    Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $u.Id -ErrorAction Stop
    return "Removed $($u.DisplayName) from '$GroupDisplayName'."
}

function Invoke-EntraLabResetMfa {
    param([Parameter(Mandatory)][string]$Upn)
    Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
    $u = Resolve-EntraLabUser -Upn $Upn
    $methods = Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction Stop
    $removed = 0
    foreach ($m in $methods) {
        # Never remove the password method (#microsoft.graph.passwordAuthenticationMethod).
        $type = $m.AdditionalProperties['@odata.type']
        if ($type -eq '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod') {
            Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $u.Id -MicrosoftAuthenticatorAuthenticationMethodId $m.Id -ErrorAction SilentlyContinue; $removed++
        } elseif ($type -eq '#microsoft.graph.phoneAuthenticationMethod') {
            Remove-MgUserAuthenticationPhoneMethod -UserId $u.Id -PhoneAuthenticationMethodId $m.Id -ErrorAction SilentlyContinue; $removed++
        }
    }
    return "Cleared $removed MFA method(s) for $($u.DisplayName); they must re-register the Authenticator."
}

function New-EntraLabUser {
    <#
        Creates a single Entra user (used both by the bulk seeder and by the
        "new hire" incident resolution). Returns the created user object plus the
        temp password.
    #>
    param(
        [Parameter(Mandatory)][string]$First,
        [Parameter(Mandatory)][string]$Last,
        [Parameter(Mandatory)][string]$MailNickname,
        [Parameter(Mandatory)][string]$Domain,
        [string]$JobTitle,
        [string]$Department,
        [string]$CompanyName,
        [string]$OfficeName,
        [string]$City,
        [string]$State,
        [string]$StreetAddress,
        [string]$PostalCode,
        [string]$MobilePhone,
        [string]$Password,
        [string]$UsageLocation = 'US'
    )
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    if (-not $Password) { $Password = New-RandomPassword }
    $upn = "$MailNickname@$Domain"

    $params = @{
        AccountEnabled    = $true
        DisplayName       = "$First $Last"
        GivenName         = $First
        Surname           = $Last
        MailNickname      = $MailNickname
        UserPrincipalName = $upn
        UsageLocation     = $UsageLocation
        PasswordProfile   = @{ Password = $Password; ForceChangePasswordNextSignIn = $true }
    }
    if ($JobTitle)      { $params.JobTitle      = $JobTitle }
    if ($Department)    { $params.Department    = $Department }
    if ($CompanyName)   { $params.CompanyName   = $CompanyName }
    if ($OfficeName)    { $params.OfficeLocation= $OfficeName }
    if ($City)          { $params.City          = $City }
    if ($State)         { $params.State         = $State }
    if ($StreetAddress) { $params.StreetAddress = $StreetAddress }
    if ($PostalCode)    { $params.PostalCode    = $PostalCode }
    if ($MobilePhone)   { $params.MobilePhone   = $MobilePhone }

    $created = New-MgUser @params -ErrorAction Stop
    return [pscustomobject]@{ User = $created; Upn = $upn; Password = $Password }
}
