<#
    Update-OfflineIdentityCache.ps1

    Fetches a batch of realistic identities from Mockaroo once and caches them to
    offline-identities.json in the repo root. After that, running any lab script
    with -Offline draws from this cache instead of the built-in name lists (or
    calling Mockaroo again) - so -Offline gives you Mockaroo-quality data with no
    API key and no internet at seed time.

    The cached file is fake, generated data - safe to commit so -Offline works
    out of the box for anyone who clones the repo.

    Usage:
      pwsh ./Update-OfflineIdentityCache.ps1              # prompts for your key, fetches 1000
      pwsh ./Update-OfflineIdentityCache.ps1 -Count 1000 -MockarooApiKey <key>

    Mockaroo's free tier caps a single request at 1,000 rows.
#>

[CmdletBinding()]
param(
    [ValidateRange(1,1000)]
    [int]$Count = 1000,

    [string]$MockarooApiKey,

    # Where to write the cache. Defaults to offline-identities.json next to this script.
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'offline-identities.json' }

if ([string]::IsNullOrWhiteSpace($MockarooApiKey)) {
    $MockarooApiKey = Read-Host "Enter your Mockaroo API key (free at mockaroo.com)" -MaskInput
}
if ([string]::IsNullOrWhiteSpace($MockarooApiKey)) { Write-Error "A Mockaroo API key is required."; return }

# Same schema the lab scripts expect from a Mockaroo record.
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
$uri  = "https://api.mockaroo.com/api/generate.json?key=$MockarooApiKey&count=$Count"

Write-Host "Requesting $Count identities from Mockaroo..." -ForegroundColor Cyan
$result = Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json'
if ($result -is [string]) { throw "Mockaroo returned an unexpected response (likely an error): $result" }

$records = @($result)
if ($records.Count -eq 0) { throw "Mockaroo returned no records." }

# Keep only the fields the lab uses, in a stable shape.
$clean = $records | ForEach-Object {
    [pscustomobject]@{
        first_name     = $_.first_name
        last_name      = $_.last_name
        street_address = $_.street_address
        city           = $_.city
        state_abbr     = $_.state_abbr
        postal_code    = [string]$_.postal_code
        mobile_phone   = $_.mobile_phone
    }
}

$clean | ConvertTo-Json -Depth 5 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Wrote $($clean.Count) identities to $OutFile" -ForegroundColor Green
Write-Host "-Offline runs will now sample from this cache. Commit the file to share it." -ForegroundColor Cyan
