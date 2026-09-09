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
    [string]$SecurityRole = 'User Administrator',

    # Occasionally, clicking "Check for new tickets" triggers a simulated Entra
    # portal outage that forces you to remediate via the CLI. Pass this to turn
    # that off.
    [switch]$DisableOutages
)

$ErrorActionPreference = 'Stop'

$LabRoot     = Split-Path -Parent $PSScriptRoot
$PublicDir   = Join-Path $PSScriptRoot 'public'
$DataDir     = Join-Path $LabRoot 'data'
$ConfigPath    = Join-Path $DataDir 'config.json'
$TicketsPath   = Join-Path $DataDir 'tickets.json'
$RosterPath    = Join-Path $DataDir 'users.json'
$ArtifactsPath = Join-Path $DataDir 'incident-artifacts.json'
$GamePath      = Join-Path $DataDir 'game.json'
$DevicesPath   = Join-Path $DataDir 'devices.json'
$script:SecurityRole = $SecurityRole

# ------------------------------- scoring ------------------------------------
# A ticket is worth 100 base points (times a priority multiplier) the moment it
# goes In Progress, decaying over time until closed. Closing via the CLI earns a
# bonus. These constants are also sent to the UI so it can show live points.
$script:PointsConfig = [pscustomobject]@{
    base            = 100
    decayPerMin     = 2      # points lost per minute in progress
    minPoints       = 10     # floor on the award for a closed ticket
    cliMultiplier   = 1.5    # bonus for closing via the CLI
    priorityMult    = [pscustomobject]@{ Urgent = 1.5; High = 1.25; Medium = 1.0; Low = 0.8 }
    # Ways to LOSE points (so rank can go down):
    improperPenalty = 40     # closing in Live mode when the fix isn't actually in place
    slaPenalty      = 15     # a still-open ticket blowing past its SLA (charged once)
    slaMinutes      = [pscustomobject]@{ Urgent = 15; High = 30; Medium = 60; Low = 120 }
}

. (Join-Path $LabRoot 'EntraLabHelpers.ps1')
. (Join-Path $LabRoot 'EntraLabGraph.ps1')   # incident actions used by Live mode

$script:GraphConnected = $false

# Simulated Entra portal outage is now PER-TICKET: exactly one ticket in the queue
# may carry willTriggerOutage. Opening that ticket activates the outage, which
# persists (portal "down") until that ticket is Resolved/Closed. Get-OutageState
# derives the live state from the tickets, so nothing here is a standing timer.
$script:OutageMessage = "Microsoft is reporting that the Entra admin center (web portal) is currently unavailable. Microsoft Graph and the CLI are still working normally - please remediate these tickets using the CLI (Microsoft Graph PowerShell / az) instead of the portal until service is restored."

function Get-OutageState {
    # Active while the triggering ticket has been opened and is still being worked
    # (Open or In Progress). Resolving/closing it restores the portal.
    $trigger = $script:tickets | Where-Object {
        $_.willTriggerOutage -and $_.outageActivated -and $_.status -ne 'Resolved' -and $_.status -ne 'Closed'
    } | Select-Object -First 1
    $active = [bool]$trigger
    return [pscustomobject]@{ active = $active; message = if ($active) { $script:OutageMessage } else { '' } }
}

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

# --------------------------------- devices ----------------------------------
# Device incidents draw from a device pool. In Live mode it's the real objects
# created by Add-EntraLabDevices.ps1 (data/devices.json). In Mock mode we
# fabricate a pool from the roster so device tickets work with no tenant.

function New-MockDevices {
    param([object[]]$People, [double]$Coverage = 0.6, [double]$SecondChance = 0.2)
    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $People) {
        if ((Get-Random -Minimum 0.0 -Maximum 1.0) -gt $Coverage) { continue }
        $count = if ((Get-Random -Minimum 0.0 -Maximum 1.0) -le $SecondChance) { 2 } else { 1 }
        for ($i = 0; $i -lt $count; $i++) {
            $os = Get-Random -InputObject $script:DeviceOSes
            $devices.Add([pscustomobject]@{
                id = [guid]::NewGuid().ToString(); displayName = (New-LabDeviceName -First $u.first -Last $u.last -OS $os)
                os = $os; enabled = $true; ownerUpn = $u.upn; ownerName = $u.displayName; ownerId = $u.id
            })
        }
    }
    return $devices.ToArray()
}

$script:devices = @()
if ($config.mode -eq 'Live') {
    $dev = Read-JsonFile -Path $DevicesPath -Default $null
    if ($dev -and $dev.devices) { $script:devices = @($dev.devices) }
} else {
    $script:devices = @(New-MockDevices -People @($roster.people))
}

# --------------------------------- game -------------------------------------

$defaultGame = [pscustomobject]@{
    score = 0; closedCount = 0; cliCloses = 0; outageCloses = 0; securityCloses = 0
    alertCloses = 0; verifyPasses = 0; maxOpen = 0; hadOpen = $false
    achievements = @()
}
$script:game = Read-JsonFile -Path $GamePath -Default $defaultGame
foreach ($p in $defaultGame.PSObject.Properties) {
    if (-not $script:game.PSObject.Properties.Name.Contains($p.Name)) {
        $script:game | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
}
$script:game.achievements = @($script:game.achievements)

function Get-GameLevel { param([int]$Score) return [Math]::Max(1, [Math]::Floor($Score / 500) + 1) }

function Get-PriorityMultiplier {
    param([string]$Priority)
    $m = $script:PointsConfig.priorityMult
    if ($m.PSObject.Properties.Name -contains $Priority) { return [double]$m.$Priority }
    return 1.0
}

function Get-TicketPotentialPoints {
    # Points a ticket is currently worth (before any CLI bonus), based on how long
    # it's been In Progress. Used both to award on close and to show live on the card.
    param([object]$Ticket)
    $cfg = $script:PointsConfig
    $base = $cfg.base * (Get-PriorityMultiplier -Priority $Ticket.priority)
    $startIso = if ($Ticket.game) { $Ticket.game.inProgressAt } else { $null }
    $elapsedMin = 0.0
    if ($startIso) { $elapsedMin = ((Get-Date).ToUniversalTime() - ([datetime]$startIso).ToUniversalTime()).TotalMinutes }
    $pts = $base - ($cfg.decayPerMin * $elapsedMin)
    return [int][Math]::Max($cfg.minPoints, [Math]::Round([Math]::Min($base, $pts)))
}

function Update-GameAchievements {
    # Returns the list of newly-unlocked achievement objects (for toasts).
    $g = $script:game
    $have = [System.Collections.Generic.HashSet[string]]::new([string[]]@($g.achievements))
    $unlock = {
        param($id)
        if (-not $have.Contains($id)) { $have.Add($id) | Out-Null; return $true }
        return $false
    }
    $newly = [System.Collections.Generic.List[string]]::new()
    $cond = @{
        'first-close'      = ($g.closedCount -ge 1)
        'half-century'     = ($g.closedCount -ge 50)
        'full-plate'       = ($g.maxOpen -ge 20)
        'inbox-zero'       = ($g.hadOpen -and (@($script:tickets | Where-Object { $_.status -ne 'Closed' }).Count -eq 0) -and (@($script:tickets).Count -gt 0))
        'cli-cowboy'       = ($g.cliCloses -ge 10)
        'keyboard-warrior' = ($g.outageCloses -ge 1)
        'threat-hunter'    = ($g.securityCloses -ge 5)
        'first-responder'  = ($g.alertCloses -ge 1)
        'perfectionist'    = ($g.verifyPasses -ge 5)
        'centurion'        = ($g.score -ge 1000)
        'high-roller'      = ($g.score -ge 5000)
    }
    foreach ($a in Get-EntraAchievementCatalog) {
        if ($cond.ContainsKey($a.Id) -and $cond[$a.Id]) {
            if (& $unlock $a.Id) { $newly.Add($a.Id) }
        }
    }
    $g.achievements = @($have)
    return @(Get-EntraAchievementCatalog | Where-Object { $_.Id -in $newly })
}

function Update-GameOpenStats {
    $openNow = @($script:tickets | Where-Object { $_.status -ne 'Closed' }).Count
    if ($openNow -gt $script:game.maxOpen) { $script:game.maxOpen = $openNow }
    if ($openNow -gt 0) { $script:game.hadOpen = $true }
}

function Invoke-SlaPenalties {
    # Charge a one-time penalty for each still-open ticket that has blown past its
    # SLA (based on priority) - so letting tickets rot actually costs you points.
    $cfg = $script:PointsConfig
    $charged = 0; $count = 0
    foreach ($t in $script:tickets) {
        if ($t.status -eq 'Closed') { continue }
        if ($t.game -and ($t.game.PSObject.Properties.Name -contains 'slaPenalized') -and $t.game.slaPenalized) { continue }
        $ageMin = ((Get-Date).ToUniversalTime() - ([datetime]$t.createdAt).ToUniversalTime()).TotalMinutes
        $sla = if ($cfg.slaMinutes.PSObject.Properties.Name -contains $t.priority) { [int]$cfg.slaMinutes.$($t.priority) } else { 60 }
        if ($ageMin -ge $sla) {
            if (-not $t.game) { $t.game = [pscustomobject]@{ inProgressAt=$null; awarded=$null; fixMethod=$null } }
            $t.game | Add-Member -NotePropertyName slaPenalized -NotePropertyValue $true -Force
            $script:game.score -= $cfg.slaPenalty
            $charged += $cfg.slaPenalty; $count++
        }
    }
    return [pscustomobject]@{ penalty = $charged; breached = $count }
}

function Test-LooksLikeCliCommand {
    <#
        The CLI bonus is claimed by pasting the actual command you ran - if you
        really used the CLI you already have it; faking a valid one costs more
        than just doing the work. This is a light sanity check that the text looks
        like a Microsoft Graph PowerShell cmdlet or an Azure CLI command, not proof.
    #>
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    # Graph PowerShell verb-Mg* cmdlet, e.g. Update-MgUser, Restore-MgDirectoryDeletedItem,
    # New-MgGroupMember, Remove-MgDirectoryRoleMemberByRef...
    if ($Command -match '(?i)\b(Get|Set|New|Update|Remove|Restore|Add|Disable|Enable|Revoke|Confirm)-Mg[A-Za-z]+') { return $true }
    # Azure CLI, e.g. az ad user update ... / az rest ...
    if ($Command -match '(?im)^\s*az\s+[a-z]') { return $true }
    return $false
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
    param([object]$Incident, [object]$Affected, [string]$RoleName, [string]$Domain, [object]$Device)

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

            # --- device actions ---
            'DisableDevice' {
                if ($Device) { $out.Detail = '[live] ' + (Invoke-EntraLabDisableDevice -DeviceId $Device.id) }
                else { $out.Detail = '[live] No device on this ticket to disable.' }
            }
            'StaleDevice' {
                $dn = if ($Device) { $Device.displayName } else { 'the device' }
                $out.Detail = "[live] '$dn' is registered but stale (90+ days) - remediate by deleting the device object."
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
            'deviceEnabled' {
                $ok = Test-EntraLabDeviceEnabled -DeviceId $v.deviceId
                $m = if ($ok) { "$($v.deviceName) is enabled again." } else { "$($v.deviceName) is still disabled." }
            }
            'deviceNotExists' {
                $ok = -not (Test-EntraLabDeviceExists -DeviceId $v.deviceId)
                $m = if ($ok) { "$($v.deviceName) has been removed." } else { "$($v.deviceName) still exists - delete it." }
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

    # Device incidents target a device from the pool; the requester is its owner.
    $device = $null
    if ($Incident.Category -eq 'Device' -and @($script:devices).Count -gt 0) {
        $device = Get-Random -InputObject @($script:devices)
        $owner = @($People | Where-Object { $_.upn -eq $device.ownerUpn }) | Select-Object -First 1
        if ($owner) { $requester = $owner }
        $affected = $requester
    }

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
        device    = if ($device) { $device.displayName } else { 'their device' }
        os        = if ($device) { $device.os } else { 'Windows' }
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
        'DisableDevice'          { $actionDetail = "[mock] Device '$($fields.device)' was disabled (accountEnabled = false)." }
        'StaleDevice'            { $actionDetail = "[mock] Device '$($fields.device)' hasn't checked in for 90+ days (stale)." }
        default                  { $actionDetail = "[mock] Simulated '$($Incident.Action)'." }
    }

    # In Live mode, actually perform the action against Entra and use its result.
    if ($Mode -eq 'Live') {
        $target = if ($affected) { $affected } else { $requester }
        $live = Invoke-LiveIncidentAction -Incident $Incident -Affected $target -RoleName $fields.role -Domain $domainSuffix -Device $device
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
        'DisableDevice'         { if ($device) { [pscustomobject]@{ kind='deviceEnabled';   deviceId=$device.id; deviceName=$device.displayName } } else { $null } }
        'StaleDevice'           { if ($device) { [pscustomobject]@{ kind='deviceNotExists'; deviceId=$device.id; deviceName=$device.displayName } } else { $null } }
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
        affectedDevice = if ($device) { [pscustomobject]@{ name=$device.displayName; id=$device.id; os=$device.os } } else { $null }
        game         = $null   # { inProgressAt, awarded, fixMethod }
        willTriggerOutage = $false   # set on at most one ticket per queue (below)
        outageActivated   = $false   # flips true the first time it's opened
        resolution   = $null
    }
}

function Invoke-TicketCheck {
    # Generate 2-5 new tickets from the incident pool allowed by the current tier.
    $catalog = Get-EntraIncidentCatalog
    if ($config.tier -ne 'Paid') { $catalog = $catalog | Where-Object { $_.Tier -eq 'Free' } }
    # Device incidents only when there's a device pool to draw from.
    if (@($script:devices).Count -eq 0) { $catalog = $catalog | Where-Object { $_.Category -ne 'Device' } }
    $people = @($roster.people)
    if ($people.Count -eq 0) { throw "The employee roster is empty - re-run to regenerate it." }

    $howMany = Get-Random -Minimum 2 -Maximum 6   # 2..5 inclusive
    $created = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $howMany; $i++) {
        $incident = $catalog | Get-Random
        $ticket = New-TicketFromIncident -Incident $incident -People $people -Mode $config.mode
        $created.Add($ticket)
    }

    # Per-ticket outage trigger: at most ONE across the whole queue. If no
    # not-yet-closed ticket already carries the trigger, one of the new tickets may
    # (silently) become it. Opening that ticket later starts the outage.
    if (-not $DisableOutages) {
        $pending = @($script:tickets | Where-Object { $_.willTriggerOutage -and $_.status -ne 'Closed' }).Count -gt 0
        $newPending = @($created | Where-Object { $_.status -ne 'Closed' })
        if (-not $pending -and $newPending.Count -gt 0 -and (Get-Random -Minimum 1 -Maximum 4) -eq 1) {  # ~1 in 3 eligible batches
            (Get-Random -InputObject $newPending).willTriggerOutage = $true
        }
    }

    $script:tickets = @($script:tickets) + $created.ToArray()
    Write-JsonFile -Path $TicketsPath -Object $script:tickets
    Write-JsonFile -Path $ConfigPath  -Object $config

    return [pscustomobject]@{ created = $created.ToArray() }
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

function Get-GamePayload {
    $unlocked = [System.Collections.Generic.HashSet[string]]::new([string[]]@($script:game.achievements))
    $ach = Get-EntraAchievementCatalog | ForEach-Object {
        [pscustomobject]@{ id=$_.Id; icon=$_.Icon; name=$_.Name; desc=$_.Desc; unlocked=$unlocked.Contains($_.Id) }
    }
    $rank = Get-EntraRankForScore -Score ([int]$script:game.score)
    return [pscustomobject]@{
        score             = [int]$script:game.score
        rank              = $rank.name
        rankIndex         = [int]$rank.index
        rankFloor         = [int]$rank.floor
        rankNextAt        = $rank.nextAt
        rankIsMax         = [bool]$rank.isMax
        totalRanks        = [int]$rank.totalRanks
        closedCount       = [int]$script:game.closedCount
        cliCloses         = [int]$script:game.cliCloses
        unlockedCount     = @($script:game.achievements).Count
        totalAchievements = @(Get-EntraAchievementCatalog).Count
        achievements      = @($ach)
        pointsConfig      = $script:PointsConfig
    }
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
        outage = (Get-OutageState)
        game = (Get-GamePayload)
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
            $chk = Invoke-TicketCheck
            $sla = Invoke-SlaPenalties            # tickets left too long lose points
            Update-GameOpenStats
            $newAch = Update-GameAchievements     # e.g. Full Plate at 20 open
            Write-JsonFile -Path $TicketsPath -Object $script:tickets
            Write-JsonFile -Path $GamePath -Object $script:game
            Send-Json -Context $Context -Object ([pscustomobject]@{
                created           = @($chk.created)
                slaPenalty        = [int]$sla.penalty
                slaBreached       = [int]$sla.breached
                newAchievements   = @($newAch)
                state             = (Get-StatePayload)
            }); return
        }

        # /api/tickets/{id}/open  (POST: first open of a ticket - may start the outage)
        if ($path -match '^/api/tickets/([^/]+)/open$' -and $method -eq 'POST') {
            $id = $Matches[1]
            $ticket = $tickets | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $ticket) { Send-Json -Context $Context -Object @{ error='Ticket not found' } -Status 404; return }
            $activated = $false
            if ($ticket.willTriggerOutage -and -not $ticket.outageActivated -and -not $DisableOutages) {
                $ticket.outageActivated = $true
                $activated = $true
                Write-JsonFile -Path $TicketsPath -Object $tickets
            }
            $os = Get-OutageState
            Send-Json -Context $Context -Object ([pscustomobject]@{ activated=$activated; outage=$os; state=(Get-StatePayload) }); return
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
            $vr = Invoke-VerifyFix -Ticket $ticket
            $newAch = @()
            if ($vr.ok) { $script:game.verifyPasses++; $newAch = Update-GameAchievements; Write-JsonFile -Path $GamePath -Object $script:game }
            Send-Json -Context $Context -Object ([pscustomobject]@{ ok=$vr.ok; checkable=$vr.checkable; message=$vr.message; newAchievements=@($newAch); game=(Get-GamePayload) }); return
        }

        # /api/tickets/{id}  (PATCH: status / assignment / resolution)
        if ($path -match '^/api/tickets/([^/]+)$' -and $method -eq 'PATCH') {
            $id = $Matches[1]
            $ticket = $tickets | Where-Object { $_.id -eq $id } | Select-Object -First 1
            if (-not $ticket) { Send-Json -Context $Context -Object @{ error='Ticket not found' } -Status 404; return }
            $body = Get-RequestBody -Context $Context
            $awarded = $null
            $note = $null

            if ($body.status) {
                $valid = @('Open','In Progress','Resolved','Closed')
                if ($body.status -notin $valid) { Send-Json -Context $Context -Object @{ error="Invalid status" } -Status 400; return }

                # Start the clock when work begins.
                if ($body.status -eq 'In Progress' -and (-not $ticket.game -or -not $ticket.game.inProgressAt)) {
                    $ticket.game = [pscustomobject]@{ inProgressAt = (Get-Date).ToUniversalTime().ToString('o'); awarded = $null; fixMethod = $null }
                }

                if ($body.status -eq 'Closed') {
                    $res = $body.resolution
                    if (-not $res -or [string]::IsNullOrWhiteSpace([string]$res.actionsTaken)) {
                        Send-Json -Context $Context -Object @{ error="Closing a ticket requires documentation (what was done)." } -Status 400; return
                    }

                    # "Fixed via CLI" (chosen, or forced) must be backed by the actual
                    # command that was run - proof-of-work for the bonus. It's forced when
                    # the portal is down, and always for the ticket that took it down (that
                    # incident can only be remediated via the CLI).
                    $outageActive = [bool](Get-OutageState).active
                    $mustCli = $outageActive -or [bool]$ticket.willTriggerOutage
                    $wantsCli   = $mustCli -or ($res.fixedVia -eq 'cli')
                    $cliCommand = [string]$res.cliCommand
                    if ($wantsCli -and [string]::IsNullOrWhiteSpace($cliCommand)) {
                        $why = if ($ticket.willTriggerOutage) { "This is the incident that took the portal down - it can only be resolved via the CLI." }
                               elseif ($outageActive) { "The portal is down, so this must be closed via the CLI." }
                               else { "You chose 'Fixed via CLI'." }
                        Send-Json -Context $Context -Object @{ error="$why Paste the exact command you ran in the 'CLI command' box." } -Status 400; return
                    }
                    $cliValid = $wantsCli -and (Test-LooksLikeCliCommand -Command $cliCommand)
                    if ($wantsCli -and (-not $cliValid)) { $note = "That didn't look like a Graph PowerShell or az command, so it was logged as a portal fix (no CLI bonus)." }

                    $ticket.resolution = [pscustomobject]@{
                        rootCause    = [string]$res.rootCause
                        actionsTaken = [string]$res.actionsTaken
                        closedBy     = if ($res.closedBy) { [string]$res.closedBy } else { 'Service Desk' }
                        closedAt     = (Get-Date).ToUniversalTime().ToString('o')
                        fixedVia     = if ($cliValid) { 'cli' } else { 'portal' }
                        cliCommand   = if ($wantsCli) { $cliCommand } else { $null }
                    }

                    # Score it (only once, and only if not already awarded).
                    if (-not $ticket.game) { $ticket.game = [pscustomobject]@{ inProgressAt = (Get-Date).ToUniversalTime().ToString('o'); awarded = $null; fixMethod = $null } }
                    if ($null -eq $ticket.game.awarded) {
                        $fixMethod = if ($cliValid) { 'cli' } else { 'portal' }

                        # "Not fixing properly": in Live mode, if the remediation isn't
                        # actually in place (verify fails), closing costs you points.
                        $improper = $false
                        if ($config.mode -eq 'Live' -and $ticket.verify) {
                            try { $vr = Invoke-VerifyFix -Ticket $ticket; if ($vr.checkable -and -not $vr.ok) { $improper = $true } } catch {}
                        }

                        if ($improper) {
                            $pts = -1 * [int]$script:PointsConfig.improperPenalty
                            $ticket.game | Add-Member -NotePropertyName improper -NotePropertyValue $true -Force
                            $note = "Closed, but the fix isn't in place yet (verify failed) - $([Math]::Abs($pts)) point penalty. Actually remediate it, then Verify to confirm."
                        } else {
                            $pts = Get-TicketPotentialPoints -Ticket $ticket
                            if ($fixMethod -eq 'cli') { $pts = [int][Math]::Round($pts * $script:PointsConfig.cliMultiplier) }
                            if ($fixMethod -eq 'cli') { $script:game.cliCloses++ }
                            if ($outageActive -and $cliValid) { $script:game.outageCloses++ }
                            if ($ticket.category -eq 'Security') { $script:game.securityCloses++ }
                            if ($ticket.channel -eq 'Alert')     { $script:game.alertCloses++ }
                        }
                        $ticket.game.awarded = $pts
                        $ticket.game.fixMethod = $fixMethod
                        $awarded = $pts
                        $script:game.score += $pts
                        $script:game.closedCount++
                    }
                }
                $ticket.status = $body.status
            }
            $ticket.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            Update-GameOpenStats
            $newAch = Update-GameAchievements
            Write-JsonFile -Path $TicketsPath -Object $tickets
            Write-JsonFile -Path $GamePath -Object $script:game
            Send-Json -Context $Context -Object ([pscustomobject]@{ ticket=$ticket; awarded=$awarded; note=$note; newAchievements=@($newAch); game=(Get-GamePayload) }); return
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
Write-Host "  Press Ctrl+C to stop (or close this terminal)." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        # Accept asynchronously and poll the wait handle in short slices. A plain,
        # fully-blocking $listener.GetContext() sits in native code and never yields
        # a safe point, so PowerShell can't act on Ctrl+C until a request happens to
        # arrive. WaitOne(250) hands control back to PowerShell ~4x/second so an
        # interactive Ctrl+C interrupts this loop promptly; the finally then closes
        # the listener.
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(250)) { }
        $context = $task.GetAwaiter().GetResult()

        # A single bad/malformed request (e.g. a POST with no Content-Length, which
        # HttpListener answers with 411 and disposes) must never take down the server.
        try { Invoke-Route -Context $context }
        catch { Write-Warning "Unhandled request error: $($_.Exception.Message)" }
    }
} finally {
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
}
