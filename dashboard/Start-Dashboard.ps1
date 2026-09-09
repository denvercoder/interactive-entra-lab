<#
    Start-Dashboard.ps1

    A tiny, dependency-free web dashboard for the Interactive Entra Lab, built
    on the .NET HttpListener that ships with PowerShell 7 - no Node, no Python,
    no extra modules. It serves a static single-page UI and a small JSON API
    that powers the help-desk "ticket" system.

    Two modes:
      -Mode Mock  (default) : no tenant needed. Affected users are drawn from a
                              locally generated employee roster for the chosen
                              fictitious company, and incident actions are only
                              simulated. Great for demoing the whole flow.
      -Mode Live            : calls incidents/Invoke-EntraIncident.ps1, which
                              performs REAL actions (disable, delete, reset...)
                              against the Entra tenant you seeded with
                              New-EntraLabUsers.ps1. Requires a Graph connection.

    Usage:
      pwsh ./dashboard/Start-Dashboard.ps1
      pwsh ./dashboard/Start-Dashboard.ps1 -Port 8080 -Company SummitRetailGroup -Tier Paid
      pwsh ./dashboard/Start-Dashboard.ps1 -Mode Live

    Then open http://localhost:8080 in a browser. Ctrl+C to stop.
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,

    [ValidateSet('Mock','Live')]
    [string]$Mode = 'Mock',

    [ValidateSet('Free','Paid')]
    [string]$Tier,

    [ValidateSet('NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo')]
    [string]$Company,

    # How many employees to fabricate for the mock roster on first run.
    [int]$MockRosterSize = 40,

    # Target a specific Entra tenant for Live mode (GUID or contoso.onmicrosoft.com).
    # Needed if you sign in with a personal Microsoft account that's a guest in a tenant.
    [string]$TenantId,

    # Which privileged directory role the "rogue admin" incident grants. Default is
    # a genuinely privileged but reversible role; use 'Global Administrator' for the
    # classic scenario if you want (be careful in a shared tenant).
    [string]$SecurityRole = 'User Administrator'
)

$ErrorActionPreference = 'Stop'

$LabRoot     = Split-Path -Parent $PSScriptRoot
$PublicDir   = Join-Path $PSScriptRoot 'public'
$DataDir     = Join-Path $LabRoot 'data'
$ConfigPath    = Join-Path $DataDir 'config.json'
$TicketsPath   = Join-Path $DataDir 'tickets.json'
$RosterPath    = Join-Path $DataDir 'users.json'
$ArtifactsPath = Join-Path $DataDir 'incident-artifacts.json'
$script:SecurityRole = $SecurityRole

. (Join-Path $LabRoot 'EntraLabHelpers.ps1')
. (Join-Path $LabRoot 'EntraLabGraph.ps1')   # incident actions used by Live mode

$script:GraphConnected = $false

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ------------------------------- persistence --------------------------------

function Read-JsonFile {
    param([string]$Path, $Default)
    if (-not (Test-Path $Path)) { return $Default }
    try {
        $raw = Get-Content -Path $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return $raw | ConvertFrom-Json
    } catch {
        Write-Warning "Could not parse $Path ($($_.Exception.Message)); using default."
        return $Default
    }
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $Object | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Add-IncidentArtifact {
    <#
        Records something a live security incident created/changed in Entra
        (a planted backdoor account, a rogue role assignment) so
        Remove-EntraLabUsers.ps1 can clean it up later.
    #>
    param([object]$Artifact)
    if (-not $Artifact) { return }
    $existing = @(Read-JsonFile -Path $ArtifactsPath -Default @())
    $Artifact | Add-Member -NotePropertyName createdAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-JsonFile -Path $ArtifactsPath -Object (@($existing) + $Artifact)
}

# --------------------------------- config -----------------------------------
# Config persists between runs. Command-line switches override the stored value.

$defaultConfig = [pscustomobject]@{
    company          = 'NimbusSoftwareSolutions'
    tier             = 'Free'
    mode             = 'Mock'
    nextTicketNumber = 1001
}
$config = Read-JsonFile -Path $ConfigPath -Default $defaultConfig

# Make sure older/partial config files gain any missing fields.
foreach ($p in $defaultConfig.PSObject.Properties) {
    if (-not $config.PSObject.Properties.Name.Contains($p.Name)) {
        $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
}

if ($PSBoundParameters.ContainsKey('Company')) { $config.company = $Company }
if ($PSBoundParameters.ContainsKey('Tier'))    { $config.tier    = $Tier }
$config.mode = $Mode
Write-JsonFile -Path $ConfigPath -Object $config

# ------------------------------- mock roster --------------------------------
# A believable set of employees for the chosen company, so mock tickets name
# real-looking people in real departments/offices. Regenerated if the company
# changes.

function New-MockRoster {
    param([string]$CompanyKey, [int]$Size)

    $template = Get-EntraCompanyTemplate -Key $CompanyKey
    $domain   = "$($template.DomainHint).onmicrosoft.com"
    $records  = Get-OfflineIdentityRecords -Count $Size -Offices $template.Offices
    $allocation = Get-DepartmentAllocation -TotalUsers $Size -Departments $template.Departments
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $roster = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($d in $template.Departments) {
        $count = [int]$allocation[$d.Key]
        if ($count -le 0) { continue }
        $deptUsers = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $count -and $idx -lt $records.Count; $i++) {
            $rec = $records[$idx]; $idx++
            $nick = Get-UniqueMailNickname -First $rec.first_name -Last $rec.last_name -Existing $existing
            if ($d.IsExecutive)              { $title = $d.ExecTitles[[Math]::Min($i, $d.ExecTitles.Count-1)] }
            elseif ($i -eq 0 -and $count -ge 2) { $title = $d.LeadTitle }
            else                             { $title = $d.ICTitles | Get-Random }
            $u = [pscustomobject]@{
                id          = [guid]::NewGuid().ToString()
                displayName = "$($rec.first_name) $($rec.last_name)"
                first       = $rec.first_name
                last        = $rec.last_name
                upn         = "$nick@$domain"
                department  = $d.DisplayName
                title       = $title
                office      = $rec.office_name
                isLead      = ($d.IsExecutive -or ($i -eq 0 -and $count -ge 2))
                manager     = $null
            }
            $deptUsers.Add($u); $roster.Add($u)
        }
        # First user in each dept is the lead; everyone else reports to them.
        if ($deptUsers.Count -ge 2) {
            $lead = $deptUsers[0]
            foreach ($u in $deptUsers | Select-Object -Skip 1) { $u.manager = $lead.displayName }
        }
    }
    return $roster
}

$roster = Read-JsonFile -Path $RosterPath -Default $null
if (-not $roster -or -not $roster.company -or $roster.company -ne $config.company) {
    Write-Host "Generating a mock employee roster for $((Get-EntraCompanyTemplate -Key $config.company).CompanyName)..." -ForegroundColor Cyan
    $people = New-MockRoster -CompanyKey $config.company -Size $MockRosterSize
    $roster = [pscustomobject]@{ company = $config.company; people = $people }
    Write-JsonFile -Path $RosterPath -Object $roster
}

# --------------------------------- tickets ----------------------------------

$tickets = Read-JsonFile -Path $TicketsPath -Default @()
$tickets = @($tickets)

function Expand-IncidentTemplate {
    param([string]$Text, [hashtable]$Fields)
    foreach ($k in $Fields.Keys) {
        $Text = $Text.Replace("{$k}", [string]$Fields[$k])
    }
    return $Text
}

function Invoke-LiveIncidentAction {
    <#
        Performs the real Entra action for an incident (Live mode). Connects to
        Graph on first use. Returns an object { Detail; BackdoorUpn; Artifact };
        on failure Detail carries a clear error string rather than throwing, so a
        bad action still files a ticket.
    #>
    param([object]$Incident, [object]$Affected, [string]$RoleName, [string]$Domain)

    $out = [pscustomobject]@{ Detail=''; BackdoorUpn=$null; Artifact=$null }

    if (-not $script:GraphConnected) {
        try { Connect-EntraLab -TenantId $TenantId | Out-Null; $script:GraphConnected = $true }
        catch { $out.Detail = "[live] Could not connect to Microsoft Graph: $($_.Exception.Message)"; return $out }
    }
    try {
        switch ($Incident.Action) {
            'DisableUser'        { $out.Detail = '[live] ' + (Invoke-EntraLabDisableUser -Upn $Affected.upn) }
            'ForcePasswordReset' { $out.Detail = '[live] ' + (Invoke-EntraLabForcePasswordReset -Upn $Affected.upn) }
            'DeleteUser'         { $out.Detail = '[live] ' + (Invoke-EntraLabDeleteUser -Upn $Affected.upn) }
            'RemoveGroupMember'  {
                $grp = if ($Affected.deptKey) { "SG-$($Affected.deptKey)" } else { "SG-AllEmployees" }
                $out.Detail = '[live] ' + (Invoke-EntraLabRemoveGroupMember -Upn $Affected.upn -GroupDisplayName $grp)
            }
            { $_ -in 'ResetMfa','TamperMfa' } { $out.Detail = '[live] ' + (Invoke-EntraLabResetMfa -Upn $Affected.upn) }

            # --- real attacker actions ---
            { $_ -in 'PrivilegeEscalation','PrivilegeEscalationAudited' } {
                $r = Invoke-EntraLabPrivilegeEscalation -Upn $Affected.upn -RoleName $RoleName
                $out.Detail = '[live] ' + $r.Detail
                $out.Artifact = $r.Artifact
                if ($Incident.Action -eq 'PrivilegeEscalationAudited') {
                    try { $out.Detail += '  Audit: ' + (Get-EntraLabRoleAudit -Upn $Affected.upn) }
                    catch { $out.Detail += '  (Audit log read failed - needs Entra ID P1/P2: ' + $_.Exception.Message + ')' }
                }
            }
            'CreateBackdoorAccount' {
                $r = New-EntraLabBackdoorAccount -Domain $Domain
                $out.Detail = '[live] ' + $r.Detail
                $out.BackdoorUpn = $r.Upn
                $out.Artifact = $r.Artifact
            }

            # --- paid, real read-backs (403 on free -> handled) ---
            'SurfaceRiskyUsers'      { $out.Detail = '[live] ' + (Invoke-EntraLabPaidRead { Get-EntraLabRiskyUsers } 'risky users') }
            'SurfaceSignInAnomalies' { $out.Detail = '[live] ' + (Invoke-EntraLabPaidRead { Get-EntraLabSignInAnomalies } 'sign-in logs') }

            # --- narrative-only (no tenant change even in Live) ---
            'SyntheticAlert'         { $out.Detail = '[alert] Illustrative security alert - no tenant change (real sign-in telemetry needs Entra ID P1/P2).' }
            'CreateNewHire'          { $out.Detail = '[live] New-hire request - no account exists yet; resolve by provisioning the user.' }
            'NameChangeRequest'      { $out.Detail = "[live] $($Affected.displayName) still shows their previous surname; update requested." }
            'FlagRiskySignIn'        { $out.Detail = "[live] Risky sign-in scenario for $($Affected.displayName) - review in Identity Protection." }
            'ConditionalAccessBlock' { $out.Detail = "[live] Conditional Access block scenario for $($Affected.displayName) - review the sign-in logs." }
            default                  { $out.Detail = "[live] No automated action for '$($Incident.Action)'." }
        }
    } catch {
        $out.Detail = "[live] Action '$($Incident.Action)' failed: $($_.Exception.Message)"
    }
    return $out
}

function Invoke-EntraLabPaidRead {
    # Runs a P1/P2 read and turns the common "needs premium" 403 into a friendly note.
    param([scriptblock]$Read, [string]$What)
    try { return (& $Read) }
    catch {
        if ($_.Exception.Message -match '(?i)license|premium|forbidden|not licensed|Authentication_RequestFromNonPremiumTenantOrB2CTenant') {
            return "Reading $What requires Entra ID P1/P2 - not available on this tenant."
        }
        return "Could not read $What : $($_.Exception.Message)"
    }
}

function Invoke-VerifyFix {
    <#
        Re-checks tenant state for a ticket's "Verify fix" button. In Mock mode the
        result is simulated from the ticket status; in Live mode it queries Graph.
        Returns { ok; checkable; message }.
    #>
    param([object]$Ticket)

    $v = $Ticket.verify
    if (-not $v) { return [pscustomobject]@{ ok=$false; checkable=$false; message='No automatic verification for this incident type - confirm manually.' } }

    if ($config.mode -ne 'Live') {
        $fixed = $Ticket.status -in @('Resolved','Closed')
        $msg = if ($fixed) { 'Mock mode: simulated as fixed (ticket is Resolved/Closed).' } else { 'Mock mode: verification is simulated - move the ticket to Resolved to represent a completed fix.' }
        return [pscustomobject]@{ ok=$fixed; checkable=$true; message=$msg }
    }

    if (-not $script:GraphConnected) {
        try { Connect-EntraLab -TenantId $TenantId | Out-Null; $script:GraphConnected = $true }
        catch { return [pscustomobject]@{ ok=$false; checkable=$true; message="Could not connect to Graph: $($_.Exception.Message)" } }
    }
    try {
        switch ($v.kind) {
            'enabled' {
                $ok = Test-EntraLabUserEnabled -Upn $v.upn
                $m = if ($ok) { "$($v.upn) is enabled again." } else { "$($v.upn) is still disabled." }
            }
            'exists' {
                $ok = Test-EntraLabUserExists -Upn $v.upn
                $m = if ($ok) { "$($v.upn) exists again (restored)." } else { "$($v.upn) is still missing - restore it from Deleted users." }
            }
            'notExists' {
                $ok = -not (Test-EntraLabUserExists -Upn $v.upn)
                $m = if ($ok) { "Backdoor account $($v.upn) is gone." } else { "Backdoor account $($v.upn) still exists - delete it." }
            }
            'inGroup' {
                if (-not $v.group) { return [pscustomobject]@{ ok=$false; checkable=$false; message='Group unknown for this ticket - verify manually.' } }
                $ok = Test-EntraLabUserInGroup -Upn $v.upn -GroupDisplayName $v.group
                $m = if ($ok) { "$($v.upn) is back in $($v.group)." } else { "$($v.upn) is not in $($v.group) yet - re-add them." }
            }
            'notInRole' {
                $ok = -not (Test-EntraLabUserInRole -Upn $v.upn -RoleName $v.role)
                $m = if ($ok) { "$($v.upn) no longer holds '$($v.role)'." } else { "$($v.upn) still holds '$($v.role)' - remove the assignment." }
            }
            default { return [pscustomobject]@{ ok=$false; checkable=$false; message='No automatic verification for this incident type.' } }
        }
        return [pscustomobject]@{ ok=$ok; checkable=$true; message=$m }
    } catch {
        return [pscustomobject]@{ ok=$false; checkable=$true; message="Verification failed: $($_.Exception.Message)" }
    }
}

function New-TicketFromIncident {
    param([object]$Incident, [object[]]$People, [string]$Mode)

    $requester = $People | Get-Random
    $affected  = $requester
    $actionDetail = ''

    # Fields available to the subject/body templates.
    $newFirst = Get-Random -InputObject $script:OfflineFirstNames
    $newLast  = Get-Random -InputObject $script:OfflineLastNames
    $oldLast  = Get-Random -InputObject ($script:OfflineLastNames | Where-Object { $_ -ne $requester.last })
    $domainSuffix = ($requester.upn -split '@')[-1]
    $backdoorMock = "{0}-{1}@{2}" -f (Get-Random -InputObject @('svc-helpdesk','svc-backup','admin-support','svc-sync')), (Get-Random -Minimum 100 -Maximum 999), $domainSuffix
    $alertWindows = @('2:14 AM and 3:47 AM','1:02 AM and 4:19 AM','3:11 AM and 3:33 AM','12:48 AM and 2:05 AM')
    $countries    = @('Nigeria','Russia','Brazil','Vietnam','Romania','Indonesia')

    $fields = @{
        name    = $requester.displayName
        first   = $requester.first
        last    = $requester.last
        dept    = $requester.department
        title   = $requester.title
        office  = $requester.office
        upn     = $requester.upn
        manager = if ($requester.manager) { $requester.manager } else { 'their manager' }
        newname = "$newFirst $newLast"
        newtitle= $requester.title
        newdept = $requester.department
        oldlast = $oldLast
        role      = $script:SecurityRole
        backdoor  = $backdoorMock
        alerttime = (Get-Random -InputObject $alertWindows)
        country   = (Get-Random -InputObject $countries)
    }

    # In mock mode we only describe what *would* happen. In live mode the server
    # calls Invoke-LiveIncidentAction (below) to actually perform it against Entra.
    switch ($Incident.Action) {
        'DisableUser'            { $actionDetail = "[mock] $($affected.displayName)'s account was disabled (accountEnabled = false)." }
        'ForcePasswordReset'     { $actionDetail = "[mock] $($affected.displayName) can no longer sign in with their old password." }
        'DeleteUser'             { $actionDetail = "[mock] $($affected.displayName)'s account was soft-deleted (recoverable for 30 days)." }
        'RemoveGroupMember'      { $actionDetail = "[mock] $($affected.displayName) was removed from the $($requester.department) group." }
        'CreateNewHire'          { $actionDetail = "[mock] New-hire request for $($fields.newname) - no account exists yet." ; $affected = $null }
        'NameChangeRequest'      { $actionDetail = "[mock] $($affected.displayName) still shows surname '$oldLast'." }
        'FlagRiskySignIn'        { $actionDetail = "[mock] A risky sign-in was simulated for $($affected.displayName)." }
        'ConditionalAccessBlock' { $actionDetail = "[mock] $($affected.displayName) is being blocked by a Conditional Access policy." }
        'ResetMfa'               { $actionDetail = "[mock] $($affected.displayName)'s MFA methods need to be reset." }
        'TamperMfa'              { $actionDetail = "[mock] $($affected.displayName)'s MFA methods were cleared (attacker sim)." }
        { $_ -in 'PrivilegeEscalation','PrivilegeEscalationAudited' } { $actionDetail = "[mock] $($affected.displayName) was granted the '$($fields.role)' role (rogue admin)." }
        'CreateBackdoorAccount'  { $actionDetail = "[mock] A backdoor account ($($fields.backdoor)) was created."; $affected = [pscustomobject]@{ displayName='Service Account'; upn=$fields.backdoor } }
        'SyntheticAlert'         { $actionDetail = "[mock] Illustrative security alert - no tenant change." }
        'SurfaceRiskyUsers'      { $actionDetail = "[mock] Would list Identity Protection risky users (real data on Paid)."; $affected = $null }
        'SurfaceSignInAnomalies' { $actionDetail = "[mock] Would list off-hours / failed sign-ins (real data on Paid)."; $affected = $null }
        default                  { $actionDetail = "[mock] Simulated '$($Incident.Action)'." }
    }

    # In Live mode, actually perform the action against Entra and use its result.
    if ($Mode -eq 'Live') {
        $target = if ($affected) { $affected } else { $requester }
        $live = Invoke-LiveIncidentAction -Incident $Incident -Affected $target -RoleName $fields.role -Domain $domainSuffix
        $actionDetail = $live.Detail
        if ($live.BackdoorUpn) {
            $fields.backdoor = $live.BackdoorUpn
            $affected = [pscustomobject]@{ displayName='Service Account'; upn=$live.BackdoorUpn }
        }
        if ($live.Artifact) { Add-IncidentArtifact -Artifact $live.Artifact }
    }

    $channel = if (($Incident.PSObject.Properties.Name -contains 'Channel') -and $Incident.Channel) { [string]$Incident.Channel } else { 'Ticket' }

    # What "Verify fix" should check for this incident (null = nothing automatable).
    $verify = switch ($Incident.Action) {
        'DisableUser'           { [pscustomobject]@{ kind='enabled';   upn=$affected.upn } }
        'DeleteUser'            { [pscustomobject]@{ kind='exists';    upn=$affected.upn } }
        'RemoveGroupMember'     { [pscustomobject]@{ kind='inGroup';   upn=$affected.upn; group=$(if ($requester.deptKey) { "SG-$($requester.deptKey)" } else { $null }) } }
        { $_ -in 'PrivilegeEscalation','PrivilegeEscalationAudited' } { [pscustomobject]@{ kind='notInRole'; upn=$affected.upn; role=$fields.role } }
        'CreateBackdoorAccount' { [pscustomobject]@{ kind='notExists'; upn=$fields.backdoor } }
        default                 { $null }
    }

    $num = [int]$config.nextTicketNumber
    $config.nextTicketNumber = $num + 1
    $prefix = if ($channel -eq 'Alert') { 'ALR' } else { 'INC' }

    return [pscustomobject]@{
        id           = [guid]::NewGuid().ToString()
        number       = "$prefix-$num"
        channel      = $channel
        createdAt    = (Get-Date).ToUniversalTime().ToString('o')
        updatedAt    = (Get-Date).ToUniversalTime().ToString('o')
        status       = 'Open'
        priority     = $Incident.Priority
        category     = $Incident.Category
        tier         = $Incident.Tier
        incidentId   = $Incident.Id
        action       = $Incident.Action
        actionDetail = $actionDetail
        resolutionHint = $Incident.ResolutionHint
        verify       = $verify
        mode         = $Mode
        subject      = Expand-IncidentTemplate -Text $Incident.Subject -Fields $fields
        body         = Expand-IncidentTemplate -Text $Incident.Body    -Fields $fields
        requester    = [pscustomobject]@{ name=$requester.displayName; upn=$requester.upn; department=$requester.department; title=$requester.title; office=$requester.office }
        affectedUser = if ($affected) { [pscustomobject]@{ name=$affected.displayName; upn=$affected.upn } } else { $null }
        resolution   = $null
    }
}

function Invoke-TicketCheck {
    # Generate 2-5 new tickets from the incident pool allowed by the current tier.
    $catalog = Get-EntraIncidentCatalog
    if ($config.tier -ne 'Paid') { $catalog = $catalog | Where-Object { $_.Tier -eq 'Free' } }
    $people = @($roster.people)
    if ($people.Count -eq 0) { throw "The employee roster is empty - re-run to regenerate it." }

    $howMany = Get-Random -Minimum 2 -Maximum 6   # 2..5 inclusive
    $created = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $howMany; $i++) {
        $incident = $catalog | Get-Random
        $ticket = New-TicketFromIncident -Incident $incident -People $people -Mode $config.mode
        $created.Add($ticket)
    }

    $script:tickets = @($script:tickets) + $created.ToArray()
    Write-JsonFile -Path $TicketsPath -Object $script:tickets
    Write-JsonFile -Path $ConfigPath  -Object $config
    return $created.ToArray()
}

# ------------------------------ HTTP plumbing --------------------------------

$mimeTypes = @{
    '.html'='text/html; charset=utf-8'; '.js'='application/javascript; charset=utf-8'
    '.css'='text/css; charset=utf-8';   '.json'='application/json; charset=utf-8'
    '.svg'='image/svg+xml';             '.ico'='image/x-icon'
}

function Send-Response {
    param($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes)
    $resp = $Context.Response
    $resp.StatusCode = $Status
    $resp.ContentType = $ContentType
    $resp.Headers.Add('Cache-Control','no-store')
    $resp.ContentLength64 = $Bytes.Length
    $resp.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $resp.OutputStream.Close()
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    $json = if ($null -eq $Object) { 'null' } else { $Object | ConvertTo-Json -Depth 12 }
    Send-Response -Context $Context -Status $Status -ContentType 'application/json; charset=utf-8' -Bytes ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-StaticFile {
    param($Context, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq '/') { $RelativePath = 'index.html' }
    $RelativePath = $RelativePath.TrimStart('/')
    $full = Join-Path $PublicDir $RelativePath
    # Prevent path traversal outside public/.
    $fullResolved = [IO.Path]::GetFullPath($full)
    if (-not $fullResolved.StartsWith([IO.Path]::GetFullPath($PublicDir))) {
        Send-Json -Context $Context -Object @{ error = 'Forbidden' } -Status 403; return
    }
    if (-not (Test-Path $fullResolved -PathType Leaf)) {
        Send-Json -Context $Context -Object @{ error = 'Not found' } -Status 404; return
    }
    $ext = [IO.Path]::GetExtension($fullResolved).ToLower()
    $ct  = if ($mimeTypes.ContainsKey($ext)) { $mimeTypes[$ext] } else { 'application/octet-stream' }
    Send-Response -Context $Context -Status 200 -ContentType $ct -Bytes ([IO.File]::ReadAllBytes($fullResolved))
}

function Get-RequestBody {
    param($Context)
    if (-not $Context.Request.HasEntityBody) { return $null }
    $reader = New-Object IO.StreamReader($Context.Request.InputStream, $Context.Request.ContentEncoding)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Close() }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-StatePayload {
    $template = Get-EntraCompanyTemplate -Key $config.company
    $open = @($tickets | Where-Object { $_.status -ne 'Closed' })
    return [pscustomobject]@{
        config  = [pscustomobject]@{
            company     = $config.company
            companyName = $template.CompanyName
            tier        = $config.tier
            mode        = $config.mode
        }
        companies = @($script:CompanyTemplates.Keys | ForEach-Object {
            [pscustomobject]@{ key = $_; name = $script:CompanyTemplates[$_].CompanyName }
        })
        stats = [pscustomobject]@{
            total      = @($tickets).Count
            open       = @($tickets | Where-Object { $_.status -eq 'Open' }).Count
            inProgress = @($tickets | Where-Object { $_.status -eq 'In Progress' }).Count
            resolved   = @($tickets | Where-Object { $_.status -eq 'Resolved' }).Count
            closed     = @($tickets | Where-Object { $_.status -eq 'Closed' }).Count
        }
        tickets = @($tickets | Sort-Object { [datetime]$_.createdAt } -Descending)
    }
}

# --------------------------------- routing -----------------------------------

function Invoke-Route {
    param($Context)
    $req    = $Context.Request
    $method = $req.HttpMethod
    $path   = $req.Url.AbsolutePath

    try {
        if ($path -eq '/api/state' -and $method -eq 'GET') {
            Send-Json -Context $Context -Object (Get-StatePayload); return
        }

        if ($path -eq '/api/tickets/check' -and $method -eq 'POST') {
            $new = Invoke-TicketCheck
            Send-Json -Context $Context -Object ([pscustomobject]@{ created = @($new); state = (Get-StatePayload) }); return
        }

        if ($path -eq '/api/config' -and $method -eq 'POST') {
            $body = Get-RequestBody -Context $Context
            if ($body.tier -in @('Free','Paid')) { $config.tier = $body.tier }
            if ($body.mode -in @('Mock','Live')) { $config.mode = $body.mode }
            if ($body.company -and $script:CompanyTemplates.Contains([string]$body.company)) {
                if ($config.company -ne $body.company) {
                    $config.company = $body.company
                    # Only fabricate a mock roster in Mock mode. In Live mode the roster
                    # comes from New-EntraLabUsers.ps1 (real accounts) - don't clobber it.
                    if ($config.mode -ne 'Live') {
                        $people = New-MockRoster -CompanyKey $config.company -Size $MockRosterSize
                        $script:roster = [pscustomobject]@{ company = $config.company; people = $people }
                        Write-JsonFile -Path $RosterPath -Object $script:roster
                    }
                }
            }
            Write-JsonFile -Path $ConfigPath -Object $config
            Send-Json -Context $Context -Object (Get-StatePayload); return
        }

        # /api/tickets/{id}/verify  (POST: re-check tenant state for the fix)
        if ($path -match '^/api/tickets/([^/]+)/verify$' -and $method -eq 'POST') {
            $id = $Matches[1]
            $ticket = $tickets | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $ticket) { Send-Json -Context $Context -Object @{ error='Ticket not found' } -Status 404; return }
            Send-Json -Context $Context -Object (Invoke-VerifyFix -Ticket $ticket); return
        }

        # /api/tickets/{id}  (PATCH: status / assignment / resolution)
        if ($path -match '^/api/tickets/([^/]+)$' -and $method -eq 'PATCH') {
            $id = $Matches[1]
            $ticket = $tickets | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $ticket) { Send-Json -Context $Context -Object @{ error='Ticket not found' } -Status 404; return }
            $body = Get-RequestBody -Context $Context

            if ($body.status) {
                $valid = @('Open','In Progress','Resolved','Closed')
                if ($body.status -notin $valid) { Send-Json -Context $Context -Object @{ error="Invalid status" } -Status 400; return }
                if ($body.status -eq 'Closed') {
                    $res = $body.resolution
                    if (-not $res -or [string]::IsNullOrWhiteSpace([string]$res.actionsTaken)) {
                        Send-Json -Context $Context -Object @{ error="Closing a ticket requires documentation (what was done)." } -Status 400; return
                    }
                    $ticket.resolution = [pscustomobject]@{
                        rootCause    = [string]$res.rootCause
                        actionsTaken = [string]$res.actionsTaken
                        closedBy     = if ($res.closedBy) { [string]$res.closedBy } else { 'Service Desk' }
                        closedAt     = (Get-Date).ToUniversalTime().ToString('o')
                    }
                }
                $ticket.status = $body.status
            }
            $ticket.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            Write-JsonFile -Path $TicketsPath -Object $tickets
            Send-Json -Context $Context -Object $ticket; return
        }

        if ($path -eq '/api/reset' -and $method -eq 'POST') {
            $script:tickets = @()
            Write-JsonFile -Path $TicketsPath -Object $script:tickets
            Send-Json -Context $Context -Object (Get-StatePayload); return
        }

        if ($path.StartsWith('/api/')) {
            Send-Json -Context $Context -Object @{ error='Unknown API route' } -Status 404; return
        }

        Send-StaticFile -Context $Context -RelativePath $path
    } catch {
        Write-Warning "Request error on $method $path : $($_.Exception.Message)"
        try { Send-Json -Context $Context -Object @{ error = $_.Exception.Message } -Status 500 } catch { }
    }
}

# --------------------------------- listen ------------------------------------

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Error "Couldn't start the dashboard on $prefix - $($_.Exception.Message). Try a different -Port."
    return
}

$template = Get-EntraCompanyTemplate -Key $config.company
Write-Host ""
Write-Host "  $($template.CompanyName) - IT Service Desk" -ForegroundColor Green
Write-Host "  Mode: $($config.mode)   Tier: $($config.tier)" -ForegroundColor DarkGray
Write-Host "  Dashboard running at $prefix" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        # A single bad/malformed request (e.g. a POST with no Content-Length, which
        # HttpListener answers with 411 and disposes) must never take down the server.
        try { Invoke-Route -Context $context }
        catch { Write-Warning "Unhandled request error: $($_.Exception.Message)" }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
