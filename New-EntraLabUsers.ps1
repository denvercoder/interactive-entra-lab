<#
    New-EntraLabUsers.ps1

    Builds a realistic Microsoft Entra ID lab for training: department security
    groups and randomly generated employees (names/addresses/phone numbers from
    the Mockaroo API, or generated locally with -Offline) wired up with job
    titles, a manager hierarchy, and group memberships - the Entra counterpart
    of New-ADLabUsers.ps1, using the same fictitious companies.

    It also writes the roster (data/users.json) and company (data/config.json)
    the ticket dashboard reads, so the dashboard brands itself as this company
    and its Live mode runs incidents against these real accounts.

    Driven interactively (just run it and answer the prompts) or non-interactively
    via parameters, for scripted/classroom use.

    REQUIREMENTS
      - PowerShell 7 and the Microsoft.Graph SDK (Install-Module Microsoft.Graph).
      - An Entra tenant and an account that can create users and groups
        (User Administrator + Groups Administrator, or Global Administrator).
        A free Entra ID tenant is fine.
      - A free Mockaroo API key (https://mockaroo.com) unless you pass -Offline.
      - Only intended for lab/training tenants. It creates real objects - use
        -DryRun to preview a run with no writes.
#>

[CmdletBinding()]
param(
    [ValidateRange(1,1000)]
    [int]$UserCount,

    [ValidateSet('NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo')]
    [string]$CompanyTemplate = 'NimbusSoftwareSolutions',

    # Skip the password-mode prompt: pass one of these to go non-interactive.
    [switch]$UseRandomPasswords,
    [string]$SharedPassword,

    # Your Mockaroo API key. Falls back to $MockarooApiKeyDefault below, then prompts.
    [string]$MockarooApiKey,

    # Generate identities locally instead of calling Mockaroo (no internet/API key needed).
    [switch]$Offline,

    # Entra requires usageLocation before licenses can be assigned; default US.
    [string]$UsageLocation = 'US',

    # Target a specific Entra tenant (GUID or domain like contoso.onmicrosoft.com).
    # REQUIRED if you sign in with a personal Microsoft account that's a guest in a tenant.
    [string]$TenantId,

    # Seeds Get-Random so a run is reproducible. Combine with -Offline for a fully
    # reproducible run (Mockaroo-sourced names are not seeded).
    [int]$Seed,

    # Preview the full plan without creating or modifying anything in Entra.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
. (Join-Path $PSScriptRoot 'EntraLabGraph.ps1')

if ($PSBoundParameters.ContainsKey('Seed')) {
    Write-Host "Seeding randomness with -Seed $Seed for a reproducible run." -ForegroundColor Cyan
    $null = Get-Random -SetSeed $Seed
}

# Paste your own Mockaroo API key here to skip the runtime prompt (ignored with -Offline).
$MockarooApiKeyDefault = ''

$DataDir           = Join-Path $PSScriptRoot 'data'
$ConfigPath        = Join-Path $DataDir 'config.json'
$RosterPath        = Join-Path $DataDir 'users.json'
$CredentialReport  = Join-Path $DataDir ("EntraLabUsers_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
# data/ is created lazily just before writing (a dry run leaves the disk untouched).

function Get-MockarooRecords {
    param([string]$ApiKey, [int]$Count)
    $schema = @(
        @{ name = 'first_name';     type = 'First Name' }
        @{ name = 'last_name';      type = 'Last Name' }
        @{ name = 'street_address'; type = 'Street Address' }
        @{ name = 'city';           type = 'City' }
        @{ name = 'state_abbr';     type = 'State (abbrev)'; onlyUSPlaces = $true }
        @{ name = 'postal_code';    type = 'Postal Code' }
        @{ name = 'mobile_phone';   type = 'Phone'; format = '###-###-####' }
    )
    $body = $schema | ConvertTo-Json -Depth 5
    $uri = "https://api.mockaroo.com/api/generate.json?key=$ApiKey&count=$Count"
    $result = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json'
    if ($result -is [string]) { throw "Mockaroo returned an unexpected response: $result" }
    return @($result)
}

# ------------------------------- prompts -----------------------------------

if (-not $Offline -and -not $PSBoundParameters.ContainsKey('MockarooApiKey') -and -not [string]::IsNullOrWhiteSpace($MockarooApiKeyDefault)) {
    $MockarooApiKey = $MockarooApiKeyDefault
}
if (-not $Offline -and [string]::IsNullOrWhiteSpace($MockarooApiKey)) {
    $MockarooApiKey = Read-Host "Enter your Mockaroo API key (free at mockaroo.com, or Ctrl+C and re-run with -Offline)" -MaskInput
}
if (-not $Offline -and [string]::IsNullOrWhiteSpace($MockarooApiKey)) {
    Write-Error "A Mockaroo API key is required (or pass -Offline)."; return
}

if ($PSBoundParameters.ContainsKey('UserCount')) {
    $userCount = $UserCount
} else {
    [int]$userCount = 0
    do { $inputVal = Read-Host "How many users do you want? (1-1000)" }
    until ([int]::TryParse($inputVal, [ref]$userCount) -and $userCount -gt 0 -and $userCount -le 1000)
}

if ($PSBoundParameters.ContainsKey('SharedPassword')) {
    $useRandomPasswords = $false
    $meetsComplexity = $SharedPassword.Length -ge 8 -and $SharedPassword -cmatch '[A-Z]' -and $SharedPassword -match '\d' -and $SharedPassword -match '[^a-zA-Z0-9]'
    if (-not $meetsComplexity) { Write-Error "SharedPassword must be 8+ chars with an uppercase letter, a number, and a special character."; return }
    $sharedPassword = $SharedPassword
} elseif ($UseRandomPasswords) {
    $useRandomPasswords = $true; $sharedPassword = $null
} else {
    do { $pwModeInput = Read-Host "Would you like random passwords? (Y/N)" } until ($pwModeInput -match '^(?i:y|n|yes|no)$')
    $useRandomPasswords = $pwModeInput -match '^(?i:y|yes)$'
    $sharedPassword = $null
    if (-not $useRandomPasswords) {
        do {
            $sharedPassword = Read-Host "Enter the password to use for every user" -MaskInput
            $meetsComplexity = $sharedPassword.Length -ge 8 -and $sharedPassword -cmatch '[A-Z]' -and $sharedPassword -match '\d' -and $sharedPassword -match '[^a-zA-Z0-9]'
            if (-not $meetsComplexity) { Write-Warning "Password must be 8+ chars with an uppercase letter, a number, and a special character." }
        } until ($meetsComplexity)
    }
}

# ------------------------------- setup -------------------------------------

$template   = Get-EntraCompanyTemplate -Key $CompanyTemplate
$CompanyName = $template.CompanyName
$Offices     = $template.Offices
$Departments = $template.Departments
Write-Host "Company template: $CompanyName ($CompanyTemplate)" -ForegroundColor Cyan

if ($DryRun) { Write-Host "==================== DRY RUN - nothing will be created in Entra ====================" -ForegroundColor Yellow }

if (-not $DryRun) { Connect-EntraLab -TenantId $TenantId | Out-Null }
$domain = if ($DryRun) { "$($template.DomainHint).onmicrosoft.com" } else { Get-EntraLabVerifiedDomain }
Write-Host ("Target domain: $domain{0}" -f $(if ($DryRun) { ' (assumed - dry run)' } else { '' })) -ForegroundColor Cyan

# identities
if ($Offline) {
    # Prefer a cached Mockaroo pull (offline-identities.json) if it's present -
    # richer than the built-in name lists. Build/refresh it with
    # Update-OfflineIdentityCache.ps1. Falls back to the built-in generator.
    $cachePath = Join-Path $PSScriptRoot 'offline-identities.json'
    $cache = $null
    if (Test-Path $cachePath) {
        try { $cache = @(Get-Content $cachePath -Raw | ConvertFrom-Json) }
        catch { Write-Warning "Couldn't read $cachePath ($($_.Exception.Message)); using built-in generator." }
    }
    if ($cache -and $cache.Count -gt 0) {
        Write-Host "Using cached Mockaroo identities (-Offline): sampling $userCount of $($cache.Count)." -ForegroundColor Cyan
        $mockData = Get-SampledIdentityRecords -Records $cache -Count $userCount
    } else {
        Write-Host "Generating $userCount identities locally (-Offline, no cache found)..." -ForegroundColor Cyan
        $mockData = Get-OfflineIdentityRecords -Count $userCount -Offices $Offices
    }
} else {
    Write-Host "Requesting $userCount identities from Mockaroo..." -ForegroundColor Cyan
    try   { $mockData = Get-MockarooRecords -ApiKey $MockarooApiKey -Count $userCount }
    catch { Write-Warning "Mockaroo failed ($($_.Exception.Message)) - falling back to local identities."; $mockData = Get-OfflineIdentityRecords -Count $userCount -Offices $Offices }
}
$mockData = @($mockData)
if ($mockData.Count -lt $userCount) { Write-Warning "Got $($mockData.Count) of $userCount identities; continuing."; $userCount = $mockData.Count }

# department groups
Write-Host "Ensuring department security groups..." -ForegroundColor Cyan
$groupIds = @{}
function New-EntraGroupIfMissing {
    param([string]$DisplayName, [string]$MailNickname, [string]$Description)
    if ($DryRun) { Write-Host "  [DryRun] Would ensure group: $DisplayName" -ForegroundColor DarkGray; return $null }
    Import-Module Microsoft.Graph.Groups -ErrorAction Stop
    $g = Get-MgGroup -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $g) {
        $g = New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -SecurityEnabled:$true -MailNickname $MailNickname -Description $Description -ErrorAction Stop
    }
    return $g.Id
}
foreach ($d in $Departments) {
    $groupIds[$d.Key] = New-EntraGroupIfMissing -DisplayName "SG-$($d.Key)" -MailNickname "sg-$($d.Key.ToLower())" -Description "Security group for the $($d.DisplayName) department"
}
$allEmpGroupId = New-EntraGroupIfMissing -DisplayName 'SG-AllEmployees' -MailNickname 'sg-allemployees' -Description 'All employees'

# allocate + create
Write-Host "Allocating $userCount users across departments..." -ForegroundColor Cyan
$allocation = Get-DepartmentAllocation -TotalUsers $userCount -Departments $Departments
$existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$recordIndex = 0
$rosterPeople = [System.Collections.Generic.List[object]]::new()
$credRows = [System.Collections.Generic.List[object]]::new()

foreach ($d in $Departments) {
    $count = [int]$allocation[$d.Key]
    $d.CreatedUsers = [System.Collections.Generic.List[object]]::new()
    if ($count -le 0) { continue }
    Write-Host "  Creating $count user(s) in $($d.DisplayName)..." -ForegroundColor DarkCyan

    for ($i = 0; $i -lt $count; $i++) {
        $rec = $mockData[$recordIndex]; $recordIndex++
        Write-Progress -Activity "Creating Entra users" -Status "$($d.DisplayName): $($rec.first_name) $($rec.last_name) ($recordIndex/$userCount)" -PercentComplete ([math]::Min(100, [math]::Round(($recordIndex/[math]::Max(1,$userCount))*100)))

        $first = $rec.first_name; $last = $rec.last_name
        $nick  = Get-UniqueMailNickname -First $first -Last $last -Existing $existing
        $office = if ($rec.PSObject.Properties.Name -contains 'office_name' -and $rec.office_name) { $Offices | Where-Object { $_.Name -eq $rec.office_name } | Select-Object -First 1 } else { $null }
        if (-not $office) { $office = Get-WeightedOffice -Offices $Offices }

        if     ($d.IsExecutive)              { $title = $d.ExecTitles[[Math]::Min($i, $d.ExecTitles.Count-1)] }
        elseif ($i -eq 0 -and $count -ge 2)  { $title = $d.LeadTitle }
        else                                 { $title = $d.ICTitles | Get-Random }

        $password = if ($useRandomPasswords) { New-RandomPassword } else { $sharedPassword }
        $upn = "$nick@$domain"

        $createdId = $null
        if ($DryRun) {
            Write-Host "    [DryRun] Would create $upn ($first $last, $title)" -ForegroundColor DarkGray
        } else {
            try {
                $res = New-EntraLabUser -First $first -Last $last -MailNickname $nick -Domain $domain -JobTitle $title `
                        -Department $d.DisplayName -CompanyName $CompanyName -OfficeName $office.Name -City $rec.city `
                        -State $rec.state_abbr -StreetAddress $rec.street_address -PostalCode $rec.postal_code `
                        -MobilePhone $rec.mobile_phone -Password $password -UsageLocation $UsageLocation
                $createdId = $res.User.Id
            } catch { Write-Warning "Failed to create $upn : $($_.Exception.Message)"; continue }
        }

        $isLead = $d.IsExecutive -or ($i -eq 0 -and $count -ge 2)
        $person = [pscustomobject]@{
            id=$createdId; displayName="$first $last"; first=$first; last=$last; upn=$upn
            department=$d.DisplayName; title=$title; office=$office.Name; isLead=$isLead; manager=$null
            deptKey=$d.Key; isCEO=($d.IsExecutive -and $i -eq 0)
        }
        $d.CreatedUsers.Add($person); $rosterPeople.Add($person)
        $credRows.Add([pscustomobject]@{ Username=$upn; Password=$password; DisplayName="$first $last"; Department=$d.DisplayName; Title=$title; Office=$office.Name })
    }
}
Write-Progress -Activity "Creating Entra users" -Completed

# manager hierarchy
Write-Host "Wiring up manager hierarchy..." -ForegroundColor Cyan
$execDept = $Departments | Where-Object { $_.IsExecutive }
$ceo = if ($execDept -and $execDept.CreatedUsers.Count -gt 0) { $execDept.CreatedUsers | Where-Object { $_.isCEO } | Select-Object -First 1 } else { $null }

function Set-EntraManager {
    param($Person, $Manager)
    if (-not $Manager) { return }
    $Person.manager = $Manager.displayName
    if ($DryRun) { Write-Host "  [DryRun] Would set $($Person.upn) manager -> $($Manager.upn)" -ForegroundColor DarkGray; return }
    try {
        Set-MgUserManagerByRef -UserId $Person.id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($Manager.id)" } -ErrorAction Stop
    } catch { Write-Warning "Couldn't set manager for $($Person.upn): $($_.Exception.Message)" }
}
foreach ($d in $Departments) {
    if ($d.CreatedUsers.Count -eq 0) { continue }
    if ($d.IsExecutive) { foreach ($u in $d.CreatedUsers) { if ($ceo -and $u.upn -ne $ceo.upn) { Set-EntraManager -Person $u -Manager $ceo } }; continue }
    $lead = $d.CreatedUsers[0]
    if ($d.CreatedUsers.Count -ge 2) { foreach ($u in ($d.CreatedUsers | Select-Object -Skip 1)) { Set-EntraManager -Person $u -Manager $lead } }
    if ($ceo) { Set-EntraManager -Person $lead -Manager $ceo }
}

# group membership
Write-Host "Populating groups..." -ForegroundColor Cyan
if (-not $DryRun) {
    Import-Module Microsoft.Graph.Groups -ErrorAction Stop
    foreach ($d in $Departments) {
        foreach ($u in $d.CreatedUsers) {
            try { New-MgGroupMember -GroupId $groupIds[$d.Key] -DirectoryObjectId $u.id -ErrorAction Stop } catch {}
            if ($allEmpGroupId) { try { New-MgGroupMember -GroupId $allEmpGroupId -DirectoryObjectId $u.id -ErrorAction Stop } catch {} }
        }
    }
} else {
    Write-Host "  [DryRun] Would add each user to their SG-<Dept> group and SG-AllEmployees." -ForegroundColor DarkGray
}

# persist roster + config + credentials (the dashboard reads these).
# A dry run writes nothing - it's a pure preview and must not clobber a real roster.
if (-not $DryRun) {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    $roster = [pscustomobject]@{ company = $CompanyTemplate; domain = $domain; people = $rosterPeople.ToArray() }
    $roster | ConvertTo-Json -Depth 10 | Set-Content -Path $RosterPath -Encoding UTF8

    $config = if (Test-Path $ConfigPath) { Get-Content $ConfigPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{ tier='Free'; mode='Mock'; nextTicketNumber=1001 } }
    $config | Add-Member -NotePropertyName company -NotePropertyValue $CompanyTemplate -Force
    $config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8

    $credRows | Export-Csv -Path $CredentialReport -NoTypeInformation
}

# summary
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. Would have created $($rosterPeople.Count) user(s)." -ForegroundColor Yellow
} else {
    Write-Host "Done. Created $($rosterPeople.Count) user(s) across $((@($Departments | Where-Object { $_.CreatedUsers.Count -gt 0 })).Count) departments in $CompanyName." -ForegroundColor Green
    Write-Host "Credentials (plaintext, lab use only) written to: $CredentialReport" -ForegroundColor Yellow
}
foreach ($d in $Departments) { if ($d.CreatedUsers.Count -gt 0) { Write-Host ("  {0,-20} {1}" -f $d.DisplayName, $d.CreatedUsers.Count) } }
Write-Host ""
if ($DryRun) {
    Write-Host "Dry run - nothing was written. Re-run without -DryRun to create these in Entra." -ForegroundColor Yellow
} else {
    Write-Host "Roster + company written to data/. Start the ticket dashboard with:" -ForegroundColor Cyan
    Write-Host "  pwsh ./dashboard/Start-Dashboard.ps1 -Mode Live" -ForegroundColor Cyan
    Write-Host "To tear this lab down:" -ForegroundColor Cyan
    Write-Host "  pwsh ./Remove-EntraLabUsers.ps1 -CompanyTemplate $CompanyTemplate" -ForegroundColor Cyan
}
