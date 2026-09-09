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
# The last three support the security incidents; on a free tenant the audit-log
# and risky-user reads will 403 (P1/P2 features) and the incidents handle that.
$script:EntraLabScopes = @(
    'User.ReadWrite.All'                      # create / update / disable / delete users
    'Group.ReadWrite.All'                     # department group membership
    'Directory.ReadWrite.All'                 # restore soft-deleted users, read domains
    'UserAuthenticationMethod.ReadWrite.All'  # reset / clear MFA methods
    'RoleManagement.ReadWrite.Directory'      # assign/remove directory roles (privilege-escalation sim)
    'AuditLog.Read.All'                       # read directory audit + sign-in logs (Paid detections)
    'IdentityRiskyUser.Read.All'              # read Identity Protection risky users (Paid detections)
)

function Test-EntraLabModules {
    <#
        Verify the CORE Graph modules are present (needed for seeding, teardown,
        and every free-tier action). The optional modules Microsoft.Graph.SignIns
        (MFA reset) and Microsoft.Graph.Reports (Paid audit / sign-in log reads)
        are imported lazily by the functions that use them, so they don't block
        core operation - a missing one only affects that specific paid action.
    #>
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

# ======================= SECURITY / ATTACKER-SIM ACTIONS ====================
# Real, findable changes that stand in for attacker behaviour. Each returns a
# detail string and (where it creates/changes something the teardown needs to
# know about) an object describing the artifact so callers can record it.

function Get-EntraLabDirectoryRole {
    <#
        Returns the (activated) directory role object for a role display name,
        activating it from its template if it isn't active yet. Entra only
        materialises a directory role once it's first used.
    #>
    param([Parameter(Mandatory)][string]$RoleName)
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    $role = Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $RoleName } | Select-Object -First 1
    if ($role) { return $role }
    $template = Get-MgDirectoryRoleTemplate -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $RoleName } | Select-Object -First 1
    if (-not $template) { throw "Directory role '$RoleName' not found (check the exact role display name)." }
    return New-MgDirectoryRole -RoleTemplateId $template.Id -ErrorAction Stop
}

function Invoke-EntraLabPrivilegeEscalation {
    <# Adds a standard user to a privileged directory role (rogue-admin sim). #>
    param([Parameter(Mandatory)][string]$Upn, [string]$RoleName = 'User Administrator')
    $u = Resolve-EntraLabUser -Upn $Upn
    $role = Get-EntraLabDirectoryRole -RoleName $RoleName
    $ref = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($u.Id)" }
    New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -BodyParameter $ref -ErrorAction Stop
    return [pscustomobject]@{
        Detail   = "Granted '$RoleName' to $($u.DisplayName) ($Upn) - a standard user that should not hold this role."
        Artifact = [pscustomobject]@{ type='roleAssignment'; upn=$Upn; userId=$u.Id; roleName=$RoleName; roleId=$role.Id }
    }
}

function Remove-EntraLabRoleAssignment {
    <# Remediation / teardown: remove a user from a directory role. #>
    param([Parameter(Mandatory)][string]$Upn, [Parameter(Mandatory)][string]$RoleName)
    $u = Resolve-EntraLabUser -Upn $Upn
    $role = Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $RoleName } | Select-Object -First 1
    if (-not $role) { return "Role '$RoleName' is not active - nothing to remove." }
    Remove-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -DirectoryObjectId $u.Id -ErrorAction Stop
    return "Removed $($u.DisplayName) from '$RoleName'."
}

function New-EntraLabBackdoorAccount {
    <# Creates a planted "service" account with a weak password (backdoor sim). #>
    param([Parameter(Mandatory)][string]$Domain)
    $labels = @('svc-helpdesk','svc-backup','admin-support','svc-sync','helpdesk-admin')
    $nick = "{0}-{1}" -f (Get-Random -InputObject $labels), (Get-Random -Minimum 100 -Maximum 999)
    $weak = Get-Random -InputObject @('Password1!','Welcome1!','ChangeMe1!','Summer2026!')
    $res = New-EntraLabUser -First 'Service' -Last 'Account' -MailNickname $nick -Domain $Domain `
            -JobTitle 'Service Account' -Department 'IT' -CompanyName '(unmanaged)' -Password $weak
    return [pscustomobject]@{
        Detail   = "Planted backdoor account $($res.Upn) with a weak password."
        Upn      = $res.Upn
        Artifact = [pscustomobject]@{ type='user'; upn=$res.Upn; userId=$res.User.Id }
    }
}

# ------------------------- Paid (P1/P2) read-backs --------------------------
# These query live premium data. On a free tenant they throw a 403 that callers
# translate into a "needs P1/P2" note rather than a hard failure.

function Get-EntraLabRoleAudit {
    <# Recent role-management audit events for a UPN (directory audit log; P1/P2). #>
    param([Parameter(Mandatory)][string]$Upn)
    Import-Module Microsoft.Graph.Reports -ErrorAction Stop
    $events = Get-MgAuditLogDirectoryAudit -Filter "activityDisplayName eq 'Add member to role'" -Top 25 -ErrorAction Stop
    $match = $events | Where-Object { $_.TargetResources.UserPrincipalName -contains $Upn } | Select-Object -First 1
    if (-not $match) { return "No matching role-assignment audit entry found (it can take a few minutes to appear)." }
    $actor = $match.InitiatedBy.User.UserPrincipalName
    return "Audit log: '$($match.ActivityDisplayName)' at $($match.ActivityDateTime) by $actor."
}

function Get-EntraLabRiskyUsers {
    <# Current Identity Protection risky users (P2). #>
    Import-Module Microsoft.Graph.Identity.SignIns -ErrorAction Stop
    $risky = Get-MgRiskyUser -Top 20 -ErrorAction Stop
    if (-not $risky -or @($risky).Count -eq 0) { return "No risky users currently reported by Identity Protection." }
    return "Risky users: " + (@($risky | ForEach-Object { "$($_.UserPrincipalName) [risk=$($_.RiskLevel)/$($_.RiskState)]" }) -join '; ')
}

# --------------------------- verification helpers ---------------------------
# Used by the dashboard's "Verify fix" button to re-check tenant state.

function Test-EntraLabUserEnabled {
    param([Parameter(Mandatory)][string]$Upn)
    $u = Resolve-EntraLabUser -Upn $Upn
    return [bool]$u.AccountEnabled
}

function Test-EntraLabUserExists {
    param([Parameter(Mandatory)][string]$Upn)
    Import-Module Microsoft.Graph.Users -ErrorAction Stop
    $u = Get-MgUser -Filter "userPrincipalName eq '$Upn'" -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$u
}

function Test-EntraLabUserInGroup {
    param([Parameter(Mandatory)][string]$Upn, [Parameter(Mandatory)][string]$GroupDisplayName)
    Import-Module Microsoft.Graph.Groups -ErrorAction Stop
    $u = Resolve-EntraLabUser -Upn $Upn
    $g = Get-MgGroup -Filter "displayName eq '$GroupDisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $g) { return $false }
    $members = Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop
    return [bool]($members | Where-Object { $_.Id -eq $u.Id })
}

function Test-EntraLabUserInRole {
    param([Parameter(Mandatory)][string]$Upn, [Parameter(Mandatory)][string]$RoleName)
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    $u = Resolve-EntraLabUser -Upn $Upn
    $role = Get-MgDirectoryRole -All -ErrorAction Stop | Where-Object { $_.DisplayName -eq $RoleName } | Select-Object -First 1
    if (-not $role) { return $false }
    $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All -ErrorAction Stop
    return [bool]($members | Where-Object { $_.Id -eq $u.Id })
}

function Get-EntraLabSignInAnomalies {
    <# Recent failed / off-hours sign-ins from the sign-in logs (P1/P2). #>
    Import-Module Microsoft.Graph.Reports -ErrorAction Stop
    $recent = Get-MgAuditLogSignIn -Top 50 -ErrorAction Stop
    $flagged = $recent | Where-Object {
        $_.Status.ErrorCode -ne 0 -or ([datetime]$_.CreatedDateTime).ToLocalTime().Hour -lt 6
    } | Select-Object -First 8
    if (-not $flagged -or @($flagged).Count -eq 0) { return "No failed or off-hours sign-ins in the recent window." }
    return (@($flagged | ForEach-Object {
        $when = ([datetime]$_.CreatedDateTime).ToLocalTime().ToString('g')
        $ok = if ($_.Status.ErrorCode -eq 0) { 'success' } else { "fail($($_.Status.ErrorCode))" }
        "$($_.UserPrincipalName) $when $ok from $($_.IpAddress)"
    }) -join ' | ')
}
