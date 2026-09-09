<#
    Pester tests for the pure logic in EntraLabHelpers.ps1 (no Graph, no network).
    Run:  Invoke-Pester ./EntraLabHelpers.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'EntraLabHelpers.ps1')
}

Describe 'Get-EntraCompanyTemplate' {
    It 'returns each known template' {
        foreach ($k in 'NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo') {
            (Get-EntraCompanyTemplate -Key $k).CompanyName | Should -Not -BeNullOrEmpty
        }
    }
    It 'defaults to Nimbus when no key is given' {
        (Get-EntraCompanyTemplate).CompanyName | Should -Be 'Nimbus Software Solutions'
    }
    It 'throws on an unknown key' {
        { Get-EntraCompanyTemplate -Key 'NopeCorp' } | Should -Throw
    }
    It 'every template has exactly one executive department' {
        foreach ($k in 'NimbusSoftwareSolutions','SummitRetailGroup','HarborLogisticsCo') {
            $t = Get-EntraCompanyTemplate -Key $k
            @($t.Departments | Where-Object { $_.IsExecutive }).Count | Should -Be 1
        }
    }
}

Describe 'New-RandomPassword' {
    It 'meets length and complexity' {
        1..50 | ForEach-Object {
            $p = New-RandomPassword
            $p.Length | Should -BeGreaterOrEqual 14
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -Match '[a-z]'
            $p | Should -Match '\d'
            $p | Should -Match '[^a-zA-Z0-9]'
        }
    }
    It 'excludes ambiguous characters (capital I/O, lowercase l, 0, 1)' {
        # Case-sensitive: lowercase o and capital L are deliberately allowed.
        1..50 | ForEach-Object { New-RandomPassword | Should -Not -MatchExactly '[IOl01]' }
    }
}

Describe 'Get-UniqueMailNickname' {
    It 'builds first-initial + last, lowercased' {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Get-UniqueMailNickname -First 'John' -Last 'Smith' -Existing $set | Should -Be 'jsmith'
    }
    It 'de-duplicates collisions' {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $a = Get-UniqueMailNickname -First 'John' -Last 'Smith' -Existing $set
        $b = Get-UniqueMailNickname -First 'Jane' -Last 'Smith' -Existing $set
        $a | Should -Be 'jsmith'
        $b | Should -Be 'jsmith1'
    }
    It 'strips non-alphanumerics' {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Get-UniqueMailNickname -First "Ma'ry" -Last "O'Brien" -Existing $set | Should -Be 'mobrien'
    }
}

Describe 'Get-DepartmentAllocation' {
    It 'allocates exactly the requested total' {
        $depts = (Get-EntraCompanyTemplate -Key 'NimbusSoftwareSolutions').Departments
        foreach ($n in 1,5,25,150,1000) {
            $alloc = Get-DepartmentAllocation -TotalUsers $n -Departments $depts
            ($alloc.Values | Measure-Object -Sum).Sum | Should -Be $n
        }
    }
    It 'keeps the executive department to 5 or fewer' {
        $depts = (Get-EntraCompanyTemplate -Key 'NimbusSoftwareSolutions').Departments
        $alloc = Get-DepartmentAllocation -TotalUsers 1000 -Departments $depts
        $alloc['Executive'] | Should -BeLessOrEqual 5
    }
}

Describe 'Get-OfflineIdentityRecords' {
    It 'returns the requested count with the expected shape' {
        $offices = (Get-EntraCompanyTemplate -Key 'HarborLogisticsCo').Offices
        $recs = Get-OfflineIdentityRecords -Count 10 -Offices $offices
        @($recs).Count | Should -Be 10
        foreach ($r in $recs) {
            $r.first_name | Should -Not -BeNullOrEmpty
            $r.last_name  | Should -Not -BeNullOrEmpty
            $r.state_abbr | Should -Not -BeNullOrEmpty
            $r.mobile_phone | Should -Match '^\d{3}-555-\d{4}$'
        }
    }
}

Describe 'Get-SampledIdentityRecords' {
    BeforeAll {
        $script:pool = 1..100 | ForEach-Object { [pscustomobject]@{ first_name = "F$_"; last_name = "L$_" } }
    }
    It 'returns the requested count when the pool is large enough' {
        (Get-SampledIdentityRecords -Records $script:pool -Count 20).Count | Should -Be 20
    }
    It 'samples without replacement when Count <= pool size' {
        $s = Get-SampledIdentityRecords -Records $script:pool -Count 100
        ($s.first_name | Sort-Object -Unique).Count | Should -Be 100
    }
    It 'wraps around (with replacement) when asked for more than the pool holds' {
        (Get-SampledIdentityRecords -Records $script:pool -Count 250).Count | Should -Be 250
    }
    It 'returns empty for an empty pool' {
        (Get-SampledIdentityRecords -Records @() -Count 5).Count | Should -Be 0
    }
    It 'is reproducible under a fixed seed' {
        $null = Get-Random -SetSeed 7; $a = Get-SampledIdentityRecords -Records $script:pool -Count 10
        $null = Get-Random -SetSeed 7; $b = Get-SampledIdentityRecords -Records $script:pool -Count 10
        ($a.first_name -join ',') | Should -Be ($b.first_name -join ',')
    }
}

Describe 'Get-EntraIncidentCatalog' {
    It 'has both Free and Paid incidents' {
        $cat = Get-EntraIncidentCatalog
        @($cat | Where-Object { $_.Tier -eq 'Free' }).Count | Should -BeGreaterThan 0
        @($cat | Where-Object { $_.Tier -eq 'Paid' }).Count | Should -BeGreaterThan 0
    }
    It 'every incident has the fields the dashboard needs' {
        foreach ($i in Get-EntraIncidentCatalog) {
            $i.Id       | Should -Not -BeNullOrEmpty
            $i.Action   | Should -Not -BeNullOrEmpty
            $i.Priority | Should -BeIn 'Low','Medium','High','Urgent'
            $i.Tier     | Should -BeIn 'Free','Paid'
            $i.Subject  | Should -Not -BeNullOrEmpty
            $i.Body     | Should -Not -BeNullOrEmpty
        }
    }
    It 'has unique incident ids' {
        $ids = (Get-EntraIncidentCatalog).Id
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
    It 'includes the free-tier attacker actions' {
        $free = Get-EntraIncidentCatalog | Where-Object { $_.Tier -eq 'Free' }
        $free.Action | Should -Contain 'PrivilegeEscalation'
        $free.Action | Should -Contain 'CreateBackdoorAccount'
        $free.Action | Should -Contain 'TamperMfa'
        $free.Action | Should -Contain 'SyntheticAlert'
    }
    It 'keeps the real P1/P2 read-back incidents on the Paid tier only' {
        $cat = Get-EntraIncidentCatalog
        foreach ($a in 'SurfaceRiskyUsers','SurfaceSignInAnomalies','PrivilegeEscalationAudited') {
            @($cat | Where-Object { $_.Action -eq $a }).Tier | Should -Be 'Paid'
        }
    }
}

Describe 'Get-EntraRankForScore' {
    It 'starts at Jr. IT Support and tops out at CISO' {
        (Get-EntraRankForScore -Score 0).name    | Should -Be 'Jr. IT Support'
        (Get-EntraRankForScore -Score 99999).name | Should -Be 'CISO'
        (Get-EntraRankForScore -Score 99999).isMax | Should -BeTrue
    }
    It 'rises and falls with the score (same score = same rank)' {
        (Get-EntraRankForScore -Score 600).name  | Should -Be 'IT Support'
        (Get-EntraRankForScore -Score 400).name  | Should -Be 'Jr. IT Support'  # dropped back
        (Get-EntraRankForScore -Score 2500).index | Should -BeGreaterThan (Get-EntraRankForScore -Score 800).index
    }
    It 'clamps a negative score to the first rank' {
        (Get-EntraRankForScore -Score -50).name | Should -Be 'Jr. IT Support'
    }
    It 'reports the next threshold except at max rank' {
        (Get-EntraRankForScore -Score 0).nextAt     | Should -Be 500
        (Get-EntraRankForScore -Score 99999).nextAt | Should -BeNullOrEmpty
    }
}

Describe 'New-LabDeviceName' {
    It 'builds a prefixed device name from the owner and OS' {
        (New-LabDeviceName -First 'John' -Last 'Smith' -OS 'Windows') | Should -MatchExactly '^WIN-JSMITH-\d{4}$'
        (New-LabDeviceName -First 'Jane' -Last 'Doe'   -OS 'macOS')   | Should -MatchExactly '^MAC-JDOE-\d{4}$'
    }
    It 'strips non-alphanumerics and caps the tag length' {
        (New-LabDeviceName -First "Ma'ry" -Last "O'Brien-Longnamehere" -OS 'iOS') | Should -MatchExactly '^IOS-[A-Z0-9]{1,8}-\d{4}$'
    }
}

Describe 'device incidents in the catalog' {
    It 'includes free-tier Device incidents with the expected actions' {
        $dev = Get-EntraIncidentCatalog | Where-Object { $_.Category -eq 'Device' }
        @($dev).Count | Should -BeGreaterOrEqual 2
        $dev.Tier   | ForEach-Object { $_ | Should -Be 'Free' }
        $dev.Action | Should -Contain 'DisableDevice'
        $dev.Action | Should -Contain 'StaleDevice'
    }
}

Describe 'Get-EntraAchievementCatalog' {
    It 'has unique ids and required fields' {
        $a = Get-EntraAchievementCatalog
        $a.Count | Should -BeGreaterThan 5
        ($a.Id | Sort-Object -Unique).Count | Should -Be $a.Count
        foreach ($x in $a) { $x.Name | Should -Not -BeNullOrEmpty; $x.Desc | Should -Not -BeNullOrEmpty; $x.Icon | Should -Not -BeNullOrEmpty }
    }
}
