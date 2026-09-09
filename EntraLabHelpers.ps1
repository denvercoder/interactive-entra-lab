<#
    EntraLabHelpers.ps1

    Pure, side-effect-free logic shared by the Interactive Entra Lab scripts and
    the dashboard: company templates, offline (no-Mockaroo) identity generation,
    department-allocation math, password generation, Entra identity helpers
    (UPN / mailNickname), and the incident catalog that drives the ticket system.

    Nothing in this file touches Microsoft Graph, the network, or the console -
    it's safe to dot-source anywhere, including from the dashboard and tests.

    The company templates are intentionally kept identical to the Active
    Directory lab (ADLabHelpers.ps1) so the two labs describe the same
    fictitious companies.
#>

# ============================ COMPANY TEMPLATES =============================
# Each template is a self-contained fictitious company: name, offices, and a
# department scaffold (weights, titles). Kept in sync with the AD lab.

$script:CompanyTemplates = [ordered]@{

    NimbusSoftwareSolutions = @{
        CompanyName = 'Nimbus Software Solutions'
        DomainHint  = 'nimbussoftware'
        Offices = @(
            @{ Name = 'Denver HQ';      City = 'Denver';  State = 'CO'; AreaCode = '303'; Weight = 60 }
            @{ Name = 'Austin Office';  City = 'Austin';  State = 'TX'; AreaCode = '512'; Weight = 20 }
            @{ Name = 'Raleigh Office'; City = 'Raleigh'; State = 'NC'; AreaCode = '919'; Weight = 20 }
        )
        Departments = @(
            @{ Key = 'Engineering';     DisplayName = 'Engineering';      Weight = 30
               LeadTitle = 'Engineering Manager'
               ICTitles  = @('Software Engineer I','Software Engineer II','Senior Software Engineer','Staff Software Engineer','QA Engineer','DevOps Engineer','Site Reliability Engineer') }
            @{ Key = 'Product';         DisplayName = 'Product';          Weight = 8
               LeadTitle = 'Product Manager'
               ICTitles  = @('Associate Product Manager','Senior Product Manager','Product Analyst','UX Designer','UX Researcher') }
            @{ Key = 'Sales';           DisplayName = 'Sales';            Weight = 15
               LeadTitle = 'Sales Manager'
               ICTitles  = @('Sales Development Representative','Account Executive','Senior Account Executive','Sales Engineer','Customer Success Manager') }
            @{ Key = 'Marketing';       DisplayName = 'Marketing';        Weight = 8
               LeadTitle = 'Marketing Manager'
               ICTitles  = @('Marketing Coordinator','Content Marketing Specialist','Digital Marketing Specialist','SEO Specialist','Brand Manager') }
            @{ Key = 'CustomerSupport'; DisplayName = 'Customer Support'; Weight = 10
               LeadTitle = 'Support Team Lead'
               ICTitles  = @('Support Specialist I','Support Specialist II','Technical Support Engineer','Customer Support Representative') }
            @{ Key = 'IT';              DisplayName = 'IT';               Weight = 7
               LeadTitle = 'IT Manager'
               ICTitles  = @('IT Support Technician','Systems Administrator','Network Administrator','Help Desk Technician','Security Analyst') }
            @{ Key = 'Finance';         DisplayName = 'Finance';          Weight = 6
               LeadTitle = 'Finance Manager'
               ICTitles  = @('Staff Accountant','Financial Analyst','Accounts Payable Specialist','Accounts Receivable Specialist','Payroll Specialist') }
            @{ Key = 'HumanResources';  DisplayName = 'Human Resources';  Weight = 5
               LeadTitle = 'HR Manager'
               ICTitles  = @('HR Coordinator','HR Generalist','Recruiter','Talent Acquisition Specialist','Benefits Administrator') }
            @{ Key = 'Legal';           DisplayName = 'Legal';            Weight = 3
               LeadTitle = 'Legal Counsel'
               ICTitles  = @('Paralegal','Legal Assistant','Compliance Analyst','Contracts Administrator') }
            @{ Key = 'Executive';       DisplayName = 'Executive';        Weight = 3
               IsExecutive = $true
               ExecTitles  = @('Chief Executive Officer','Chief Operating Officer','Chief Technology Officer','Chief Financial Officer','Chief Marketing Officer') }
        )
    }

    SummitRetailGroup = @{
        CompanyName = 'Summit Retail Group'
        DomainHint  = 'summitretail'
        Offices = @(
            @{ Name = 'Chicago HQ';                 City = 'Chicago'; State = 'IL'; AreaCode = '312'; Weight = 50 }
            @{ Name = 'Dallas Distribution Center'; City = 'Dallas';  State = 'TX'; AreaCode = '214'; Weight = 25 }
            @{ Name = 'Atlanta Office';             City = 'Atlanta'; State = 'GA'; AreaCode = '404'; Weight = 25 }
        )
        Departments = @(
            @{ Key = 'Merchandising';    DisplayName = 'Merchandising';    Weight = 15
               LeadTitle = 'Merchandising Manager'
               ICTitles  = @('Buyer','Assistant Buyer','Merchandise Planner','Inventory Analyst') }
            @{ Key = 'StoreOperations';  DisplayName = 'Store Operations'; Weight = 30
               LeadTitle = 'Store Operations Manager'
               ICTitles  = @('Store Manager','Assistant Store Manager','Sales Associate','Cashier','Visual Merchandiser') }
            @{ Key = 'LossPrevention';   DisplayName = 'Loss Prevention';  Weight = 6
               LeadTitle = 'Loss Prevention Manager'
               ICTitles  = @('Loss Prevention Officer','Asset Protection Specialist','Security Analyst') }
            @{ Key = 'SupplyChain';      DisplayName = 'Supply Chain';     Weight = 10
               LeadTitle = 'Supply Chain Manager'
               ICTitles  = @('Logistics Coordinator','Warehouse Supervisor','Inventory Control Specialist','Distribution Analyst') }
            @{ Key = 'Marketing';        DisplayName = 'Marketing';        Weight = 8
               LeadTitle = 'Marketing Manager'
               ICTitles  = @('Marketing Coordinator','Digital Marketing Specialist','Brand Manager','Social Media Specialist') }
            @{ Key = 'CustomerService';  DisplayName = 'Customer Service'; Weight = 10
               LeadTitle = 'Customer Service Manager'
               ICTitles  = @('Customer Service Representative','Support Specialist') }
            @{ Key = 'IT';               DisplayName = 'IT';               Weight = 7
               LeadTitle = 'IT Manager'
               ICTitles  = @('IT Support Technician','Systems Administrator','Network Administrator','POS Systems Specialist','Security Analyst') }
            @{ Key = 'Finance';          DisplayName = 'Finance';          Weight = 6
               LeadTitle = 'Finance Manager'
               ICTitles  = @('Staff Accountant','Financial Analyst','Accounts Payable Specialist','Payroll Specialist') }
            @{ Key = 'HumanResources';   DisplayName = 'Human Resources';  Weight = 5
               LeadTitle = 'HR Manager'
               ICTitles  = @('HR Coordinator','HR Generalist','Recruiter','Benefits Administrator') }
            @{ Key = 'Executive';        DisplayName = 'Executive';        Weight = 3
               IsExecutive = $true
               ExecTitles  = @('Chief Executive Officer','Chief Operating Officer','Chief Financial Officer','Chief Merchandising Officer','Chief Marketing Officer') }
        )
    }

    HarborLogisticsCo = @{
        CompanyName = 'Harbor Logistics Co'
        DomainHint  = 'harborlogistics'
        Offices = @(
            @{ Name = 'Newark Terminal';   City = 'Newark';   State = 'NJ'; AreaCode = '973'; Weight = 40 }
            @{ Name = 'Savannah Terminal'; City = 'Savannah'; State = 'GA'; AreaCode = '912'; Weight = 30 }
            @{ Name = 'Houston Terminal';  City = 'Houston';  State = 'TX'; AreaCode = '713'; Weight = 30 }
        )
        Departments = @(
            @{ Key = 'Operations';       DisplayName = 'Operations';        Weight = 25
               LeadTitle = 'Operations Manager'
               ICTitles  = @('Dispatcher','Operations Coordinator','Route Planner','Logistics Analyst') }
            @{ Key = 'FleetMaintenance'; DisplayName = 'Fleet Maintenance'; Weight = 12
               LeadTitle = 'Fleet Maintenance Manager'
               ICTitles  = @('Diesel Mechanic','Fleet Technician','Maintenance Coordinator') }
            @{ Key = 'Warehousing';      DisplayName = 'Warehousing';       Weight = 18
               LeadTitle = 'Warehouse Manager'
               ICTitles  = @('Warehouse Associate','Forklift Operator','Inventory Specialist','Shipping Clerk') }
            @{ Key = 'CustomerService';  DisplayName = 'Customer Service';  Weight = 8
               LeadTitle = 'Customer Service Manager'
               ICTitles  = @('Customer Service Representative','Freight Coordinator') }
            @{ Key = 'Sales';            DisplayName = 'Sales';             Weight = 10
               LeadTitle = 'Sales Manager'
               ICTitles  = @('Account Executive','Sales Representative','Business Development Representative') }
            @{ Key = 'IT';               DisplayName = 'IT';                Weight = 6
               LeadTitle = 'IT Manager'
               ICTitles  = @('IT Support Technician','Systems Administrator','Network Administrator','Security Analyst') }
            @{ Key = 'Finance';          DisplayName = 'Finance';           Weight = 6
               LeadTitle = 'Finance Manager'
               ICTitles  = @('Staff Accountant','Financial Analyst','Accounts Payable Specialist','Payroll Specialist') }
            @{ Key = 'HumanResources';   DisplayName = 'Human Resources';   Weight = 5
               LeadTitle = 'HR Manager'
               ICTitles  = @('HR Coordinator','HR Generalist','Recruiter','Safety & Compliance Specialist') }
            @{ Key = 'Executive';        DisplayName = 'Executive';         Weight = 3
               IsExecutive = $true
               ExecTitles  = @('Chief Executive Officer','Chief Operating Officer','Chief Financial Officer','VP of Logistics') }
        )
    }
}

function Get-EntraCompanyTemplate {
    param([string]$Key)
    if (-not $Key) { $Key = 'NimbusSoftwareSolutions' }
    if (-not $script:CompanyTemplates.Contains($Key)) {
        throw "Unknown company template '$Key'. Valid: $($script:CompanyTemplates.Keys -join ', ')"
    }
    return $script:CompanyTemplates[$Key]
}

# ================================ HELPERS ===================================

function New-RandomPassword {
    param([int]$Length = 14)
    # Ambiguous characters (I, O, l, 0, 1) are excluded so credentials are easy to type by hand.
    $upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = [char[]]'abcdefghijkmnopqrstuvwxyz'
    $digits  = [char[]]'23456789'
    $special = [char[]]'!@#$%^&*-_+='
    $all = $upper + $lower + $digits + $special

    $passChars = @(($upper | Get-Random), ($lower | Get-Random), ($digits | Get-Random), ($special | Get-Random))
    for ($i = $passChars.Count; $i -lt $Length; $i++) { $passChars += $all | Get-Random }

    -join ($passChars | Sort-Object { Get-Random })
}

function Get-UniqueMailNickname {
    <#
        Entra's equivalent of a SamAccountName: the local part of the UPN and the
        mailNickname. First-initial + last name, lowercased, de-duplicated
        against an existing set (case-insensitive).
    #>
    param(
        [string]$First,
        [string]$Last,
        [System.Collections.Generic.HashSet[string]]$Existing
    )
    $base = (($First.Substring(0,1) + $Last) -replace '[^a-zA-Z0-9]', '').ToLower()
    if ($base.Length -eq 0) { $base = 'user' }

    $candidate = if ($base.Length -gt 20) { $base.Substring(0,20) } else { $base }
    $n = 1
    while ($Existing.Contains($candidate)) {
        $suffix = [string]$n
        $maxBaseLen = 20 - $suffix.Length
        $trimmedBase = if ($base.Length -gt $maxBaseLen) { $base.Substring(0,$maxBaseLen) } else { $base }
        $candidate = "$trimmedBase$suffix"
        $n++
    }
    [void]$Existing.Add($candidate)
    return $candidate
}

function Get-DepartmentAllocation {
    param([int]$TotalUsers, [array]$Departments)

    $totalWeight = ($Departments | ForEach-Object { $_.Weight } | Measure-Object -Sum).Sum
    $floor = @{}
    $remainder = @{}
    foreach ($d in $Departments) {
        $raw = $TotalUsers * $d.Weight / $totalWeight
        $floor[$d.Key] = [math]::Floor($raw)
        $remainder[$d.Key] = $raw - $floor[$d.Key]
    }

    $assigned = ($floor.Values | Measure-Object -Sum).Sum
    $leftover = $TotalUsers - $assigned
    $order = $remainder.GetEnumerator() | Sort-Object -Property Value -Descending
    foreach ($entry in $order) {
        if ($leftover -le 0) { break }
        $floor[$entry.Key]++
        $leftover--
    }

    # Keep the C-suite realistically small no matter how large the class is.
    $execKey = ($Departments | Where-Object { $_.IsExecutive } | Select-Object -First 1).Key
    $icKey   = ($Departments | Sort-Object -Property { $_.Weight } -Descending | Where-Object { -not $_.IsExecutive } | Select-Object -First 1).Key
    if ($execKey -and $floor.ContainsKey($execKey) -and $floor[$execKey] -gt 5) {
        $overflow = $floor[$execKey] - 5
        $floor[$execKey] = 5
        if ($icKey) { $floor[$icKey] += $overflow }
    }
    return $floor
}

function Get-WeightedOffice {
    param([array]$Offices)
    $totalWeight = ($Offices | ForEach-Object { $_.Weight } | Measure-Object -Sum).Sum
    $roll = Get-Random -Minimum 1 -Maximum ($totalWeight + 1)
    $running = 0
    foreach ($o in $Offices) {
        $running += $o.Weight
        if ($roll -le $running) { return $o }
    }
    return $Offices[0]
}

# ========================= OFFLINE IDENTITY FALLBACK =========================
# Used when -Offline is passed, or automatically as a fallback if the Mockaroo
# API call fails. Fully deterministic under -Seed since it's driven by Get-Random.

$script:OfflineFirstNames = @(
    'James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda','David','Elizabeth',
    'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
    'Christopher','Nancy','Daniel','Lisa','Matthew','Betty','Anthony','Margaret','Mark','Sandra',
    'Donald','Ashley','Steven','Kimberly','Andrew','Emily','Paul','Donna','Joshua','Michelle',
    'Kenneth','Dorothy','Kevin','Carol','Brian','Amanda','George','Melissa','Edward','Deborah',
    'Ronald','Stephanie','Timothy','Rebecca','Jason','Sharon','Jeffrey','Laura','Ryan','Cynthia',
    'Jacob','Kathleen','Gary','Amy','Nicholas','Angela','Eric','Shirley','Jonathan','Anna',
    'Stephen','Brenda','Larry','Pamela','Justin','Emma','Scott','Nicole','Brandon','Helen',
    'Benjamin','Samantha','Samuel','Katherine','Gregory','Christine','Alexander','Debra','Frank','Rachel',
    'Patrick','Carolyn','Raymond','Janet','Jack','Maria','Dennis','Heather','Jerry','Diane'
)

$script:OfflineLastNames = @(
    'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
    'Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor','Moore','Jackson','Martin',
    'Lee','Perez','Thompson','White','Harris','Sanchez','Clark','Ramirez','Lewis','Robinson',
    'Walker','Young','Allen','King','Wright','Scott','Torres','Nguyen','Hill','Flores',
    'Green','Adams','Nelson','Baker','Hall','Rivera','Campbell','Mitchell','Carter','Roberts',
    'Gomez','Phillips','Evans','Turner','Diaz','Parker','Cruz','Edwards','Collins','Reyes',
    'Stewart','Morris','Morales','Murphy','Cook','Rogers','Gutierrez','Ortiz','Morgan','Cooper',
    'Peterson','Bailey','Reed','Kelly','Howard','Ramos','Kim','Cox','Ward','Richardson',
    'Watson','Brooks','Chavez','Wood','Bennett','Gray','Mendoza','Ruiz','Hughes','Price',
    'Alvarez','Castillo','Sanders','Patel','Myers','Long','Ross','Foster','Jimenez','Powell'
)

$script:OfflineStreetNames = @(
    'Main St','Oak Ave','Maple Dr','Cedar Ln','Elm St','Washington Ave','Park Rd','Sunset Blvd',
    'Highland Ave','Lakeview Dr','River Rd','2nd St','3rd Ave','5th St','Pine St','Hill St',
    'Church St','Spring St','Meadow Ln','Ridge Rd'
)

function Get-OfflineIdentityRecords {
    <#
        Local stand-in for a Mockaroo call. Returns $Count pscustomobjects with
        first_name, last_name, street_address, city, state_abbr, postal_code,
        mobile_phone - built from the embedded lists plus the company's offices.
    #>
    param(
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][array]$Offices
    )
    $records = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $office = Get-WeightedOffice -Offices $Offices
        $records.Add([pscustomobject]@{
            first_name     = Get-Random -InputObject $script:OfflineFirstNames
            last_name      = Get-Random -InputObject $script:OfflineLastNames
            street_address = ("{0} {1}" -f (Get-Random -Minimum 100 -Maximum 9999), (Get-Random -InputObject $script:OfflineStreetNames))
            city           = $office.City
            state_abbr     = $office.State
            postal_code    = '{0:D5}' -f (Get-Random -Minimum 10000 -Maximum 99999)
            mobile_phone   = ('{0}-555-{1:D4}' -f $office.AreaCode, (Get-Random -Minimum 0 -Maximum 9999))
            office_name    = $office.Name
        })
    }
    return $records
}

# ============================== INCIDENT CATALOG =============================
# The pool the dashboard draws from when you click "Check for new tickets".
#
# Each incident is a template describing a real-world help-desk situation. The
# dashboard picks a random affected user, performs the Action against Entra
# (in live mode) or simulates it (in mock mode), and files a ticket written in
# that employee's voice. Placeholders filled at runtime:
#   {name} {first} {last} {dept} {title} {office} {upn} {manager}
#   {newname} {newtitle} {newdept} {oldlast}
#
# Tier:   Free  = works on Entra ID Free.
#         Paid  = needs Entra ID P1/P2 features (only offered when the toggle is Paid).
# Action: a verb the incident engine knows how to perform and later verify.

function Get-EntraIncidentCatalog {
    return @(
        [pscustomobject]@{
            Id='disabled-signin'; Tier='Free'; Category='Account access'; Priority='High'; Action='DisableUser'
            Subject='Locked out - "your account has been disabled"'
            Body='Hi Service Desk, this is {name} in {dept} at our {office} location. I''m trying to sign in to Microsoft 365 and it says "Your account has been disabled. Please contact your administrator." I have a deadline this afternoon - can someone take a look ASAP? Thanks, {first}'
            ResolutionHint='Re-enable the account (set Account enabled = Yes) and confirm the user can sign in.'
        }
        [pscustomobject]@{
            Id='forgot-password'; Tier='Free'; Category='Account access'; Priority='Medium'; Action='ForcePasswordReset'
            Subject='Forgot my password over the weekend'
            Body='Hey, {first} {last} here ({title}, {dept}). I completely forgot my password over the weekend and I''m locked out now. Can you set a temporary one and I''ll change it when I log in? My sign-in is {upn}.'
            ResolutionHint='Reset the password to a temporary value with "change at next sign-in" required, and pass the temp password to the user securely.'
        }
        [pscustomobject]@{
            Id='account-deleted'; Tier='Free'; Category='Provisioning'; Priority='Urgent'; Action='DeleteUser'
            Subject='One of my team members has vanished from everything'
            Body='This is {manager}. {name} on my team ({title}) can''t log in at all this morning and doesn''t show up in Teams, Outlook, or SharePoint anymore - it''s like the account was deleted. Nobody on my side touched it. Can you investigate and get them back? This is blocking their work.'
            ResolutionHint='The account was soft-deleted. Restore it from Entra''s Deleted users (recoverable within 30 days), then confirm sign-in and group access.'
        }
        [pscustomobject]@{
            Id='new-hire'; Tier='Free'; Category='Provisioning'; Priority='Medium'; Action='CreateNewHire'
            Subject='New hire starting Monday - please provision account'
            Body='Hi IT, HR here. We have a new hire starting Monday: {newname}, joining as {newtitle} in {newdept}. Please create their account, set a temporary password, and add them to the standard {newdept} groups. Their manager will be {manager}. Let me know the sign-in name once it''s ready.'
            ResolutionHint='Create the Entra user (temp password, change at next sign-in), set department/title/manager, and add to the department group.'
        }
        [pscustomobject]@{
            Id='group-access'; Tier='Free'; Category='Access request'; Priority='Low'; Action='RemoveGroupMember'
            Subject='Lost access to the {dept} shared resources'
            Body='Hi, {first} in {dept}. I used to be able to get into the {dept} Team and shared mailbox but since this week I get "you don''t have access". I think I got dropped from the group somehow. Can you add me back? Thanks!'
            ResolutionHint='Re-add the user to their department group (they were removed). Confirm access is restored.'
        }
        [pscustomobject]@{
            Id='name-change'; Tier='Free'; Category='Account change'; Priority='Low'; Action='NameChangeRequest'
            Subject='Last name change after getting married'
            Body='Hi! {first} here ({dept}). I got married recently and my email and display name still show my old last name, {oldlast}. Could you update my profile to my new last name, {last}? No rush but it''s a bit awkward on external emails. Thank you!'
            ResolutionHint='Update display name / surname (and optionally UPN + mailNickname per company policy). Confirm with the user.'
        }
        [pscustomobject]@{
            Id='risky-signin'; Tier='Paid'; Category='Security'; Priority='High'; Action='FlagRiskySignIn'
            Subject='[Identity Protection] Risky sign-in flagged'
            Body='Automated alert on behalf of Security: a risky sign-in was detected on {name}''s account ({upn}) - atypical travel / unfamiliar location. Identity Protection has raised the user risk level. Please review the risk detection, confirm whether it was the user, and dismiss or confirm the risk. If compromised, revoke sessions and force a password reset.'
            ResolutionHint='Review the risk detection in Identity Protection. If safe, dismiss user risk. If not, confirm compromise, revoke sign-in sessions, and reset the password.'
        }
        [pscustomobject]@{
            Id='ca-blocked'; Tier='Paid'; Category='Security'; Priority='Medium'; Action='ConditionalAccessBlock'
            Subject='Blocked by security policy while traveling'
            Body='Hi Service Desk, {first} {last} ({title}, {dept}). I''m traveling for work and I keep getting "You cannot access this right now - your sign-in was blocked by an organization policy." I can''t get to email or files. Is this a Conditional Access thing? Can you help me get access from this location?'
            ResolutionHint='Review the Conditional Access sign-in failure. Confirm identity, then grant a temporary exception / named location, or walk the user through compliant sign-in. Do not disable the policy tenant-wide.'
        }
        [pscustomobject]@{
            Id='mfa-reset'; Tier='Paid'; Category='Account access'; Priority='Medium'; Action='ResetMfa'
            Subject='New phone - can''t complete MFA'
            Body='Hey, {first} in {dept}. I got a new phone and I no longer have the Authenticator app set up, so I can''t get past the "approve sign-in" prompt. Can you reset my MFA so I can re-register the Authenticator on my new device? My account is {upn}.'
            ResolutionHint='Delete the user''s existing authentication methods (or require re-registration), then have the user re-enroll the Authenticator app.'
        }
    )
}
