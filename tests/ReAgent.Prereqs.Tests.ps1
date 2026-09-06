BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Prereqs.psm1" -Force

    function Get-TestInv {
        param($Py = 'C:\py.exe', $PyVer = [version]'3.11.0', $Jdk = 'C:\java.exe',
            $JdkVer = [version]'21.0.0', $Cdb = 'C:\cdb.exe', $Uv = 'C:\uv.exe',
            $Ghidra = 'C:\ghidra', $GhidraVer = [version]'12.1.2')
        [PSCustomObject]@{
            Python  = $Py; PythonVersion = $PyVer; Jdk = $Jdk; JdkVersion = $JdkVer
            Cdb     = $Cdb; Uv = $Uv; GhidraRoot = $Ghidra; GhidraVersion = $GhidraVer
        }
    }
}

Describe 'Get-MissingPrereq' {
    BeforeEach {
        Mock -ModuleName ReAgent.Prereqs Get-GhidraJavaMinimum { [version]'21.0' }
    }

    It 'reports nothing missing on a fully provisioned host' {
        Get-MissingPrereq -Inventory (Get-TestInv) | Should -BeNullOrEmpty
    }

    It 'reports python when it is absent' {
        Get-MissingPrereq -Inventory (Get-TestInv -Py $null -PyVer $null) |
            Should -Contain 'python'
    }

    It 'reports python when it is present but older than 3.10' {
        Get-MissingPrereq -Inventory (Get-TestInv -PyVer ([version]'3.9.7')) |
            Should -Contain 'python'
    }

    It 'accepts python 3.10 exactly' {
        Get-MissingPrereq -Inventory (Get-TestInv -PyVer ([version]'3.10.0')) |
            Should -Not -Contain 'python'
    }

    It 'reports cdb when it is absent' {
        Get-MissingPrereq -Inventory (Get-TestInv -Cdb $null) | Should -Contain 'cdb'
    }

    It 'reports uv when it is absent' {
        Get-MissingPrereq -Inventory (Get-TestInv -Uv $null) | Should -Contain 'uv'
    }

    It 'does not require a JDK when Ghidra is not installed' {
        Get-MissingPrereq -Inventory (Get-TestInv -Jdk $null -JdkVer $null -Ghidra $null) |
            Should -Not -Contain 'jdk'
    }

    It 'requires a JDK when Ghidra is installed' {
        Get-MissingPrereq -Inventory (Get-TestInv -Jdk $null -JdkVer $null) |
            Should -Contain 'jdk'
    }

    It 'reports jdk when the installed JDK is older than Ghidra demands' {
        Get-MissingPrereq -Inventory (Get-TestInv -JdkVer ([version]'17.0')) |
            Should -Contain 'jdk'
    }

    It 'accepts a JDK newer than Ghidra demands, since Ghidra sets no maximum' {
        # This host runs OpenJDK 25 against Ghidra 12.1.2, whose
        # application.java.max is empty. Verified working end to end.
        Get-MissingPrereq -Inventory (Get-TestInv -JdkVer ([version]'25.0')) |
            Should -Not -Contain 'jdk'
    }

    It 'reports every missing prerequisite, not just the first' {
        $m = Get-MissingPrereq -Inventory (Get-TestInv -Py $null -PyVer $null -Cdb $null -Uv $null)
        $m | Should -Contain 'python'
        $m | Should -Contain 'cdb'
        $m | Should -Contain 'uv'
    }
}

Describe 'Get-GhidraJavaMinimum' {
    It 'reads application.java.min out of Ghidra application.properties' {
        $root = Join-Path $TestDrive 'ghidra_12.1.2_PUBLIC'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'Ghidra') -Force
        @('application.version=12.1.2', 'application.java.min=21', 'application.java.max=') |
            Set-Content (Join-Path $root 'Ghidra\application.properties')
        Get-GhidraJavaMinimum -GhidraRoot $root | Should -Be ([version]'21.0')
    }

    It 'falls back to a safe default when the file is unreadable' {
        Get-GhidraJavaMinimum -GhidraRoot (Join-Path $TestDrive 'nope') |
            Should -Be ([version]'21.0')
    }
}

Describe 'Test-PrereqSatisfied' {
    It 'is true when nothing is missing' {
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { @() }
        Test-PrereqSatisfied -Inventory ([PSCustomObject]@{}) | Should -BeTrue
    }

    It 'is false when something is missing' {
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { @('python') }
        Test-PrereqSatisfied -Inventory ([PSCustomObject]@{}) | Should -BeFalse
    }

    It 'survives Get-MissingPrereq returning an unrolled empty array' {
        # Same trap as Assert-Preflight: @() unrolls to $null on return and
        # $null.Count throws under StrictMode.
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { }
        { Test-PrereqSatisfied -Inventory ([PSCustomObject]@{}) } | Should -Not -Throw
    }
}

Describe 'Install-Prereq' {
    It 'refuses to install cdb silently and explains both routes' {
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { @('cdb') }
        { Install-Prereq -Inventory ([PSCustomObject]@{}) -Confirm:$false } |
            Should -Throw '*WinDbg*'
    }

    It 'installs only what is actually missing' {
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { @('uv') }
        Mock -ModuleName ReAgent.Prereqs Invoke-CommandLine { }
        Install-Prereq -Inventory ([PSCustomObject]@{}) -Confirm:$false
        Should -Invoke -ModuleName ReAgent.Prereqs Invoke-CommandLine -Times 1 -Exactly
    }

    It 'does nothing at all when nothing is missing' {
        Mock -ModuleName ReAgent.Prereqs Get-MissingPrereq { @() }
        Mock -ModuleName ReAgent.Prereqs Invoke-CommandLine { }
        Install-Prereq -Inventory ([PSCustomObject]@{}) -Confirm:$false
        Should -Invoke -ModuleName ReAgent.Prereqs Invoke-CommandLine -Times 0 -Exactly
    }
}
