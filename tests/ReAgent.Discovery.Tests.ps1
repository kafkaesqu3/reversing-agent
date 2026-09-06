BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
}

Describe 'Compare-VersionAtLeast' {
    It 'accepts an equal version' {
        Compare-VersionAtLeast -Actual ([version]'3.10.0') -Minimum ([version]'3.10.0') |
            Should -BeTrue
    }
    It 'accepts a newer version' {
        Compare-VersionAtLeast -Actual ([version]'3.12.1') -Minimum ([version]'3.10.0') |
            Should -BeTrue
    }
    It 'rejects an older version' {
        Compare-VersionAtLeast -Actual ([version]'3.9.7') -Minimum ([version]'3.10.0') |
            Should -BeFalse
    }
    It 'rejects a null actual version' {
        Compare-VersionAtLeast -Actual $null -Minimum ([version]'3.10.0') | Should -BeFalse
    }
    It 'compares numerically, not lexically' {
        # '3.9' > '3.10' as strings. This is the bug the [version] cast prevents.
        Compare-VersionAtLeast -Actual ([version]'3.9.0') -Minimum ([version]'3.10.0') |
            Should -BeFalse
    }
}

Describe 'Get-PythonVersion' {
    It 'parses the standard python --version banner' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { 'Python 3.11.4' }
        Get-PythonVersion -PythonPath 'python.exe' | Should -Be ([version]'3.11.4')
    }
    It 'parses a two-component version' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { 'Python 3.13' }
        Get-PythonVersion -PythonPath 'python.exe' | Should -Be ([version]'3.13')
    }
    It 'returns null when the interpreter cannot be run' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { throw 'not found' }
        Get-PythonVersion -PythonPath 'nope.exe' | Should -BeNullOrEmpty
    }
    It 'returns null when the output is not a version banner' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { 'command not found' }
        Get-PythonVersion -PythonPath 'nope.exe' | Should -BeNullOrEmpty
    }
}

Describe 'Find-Executable' {
    It 'returns the first path when the command resolves' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { 'C:\Python\python.exe' }
        Find-Executable -Name 'python' | Should -Be 'C:\Python\python.exe'
    }
    It 'returns the first of several matches' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine {
            @('C:\ProgramData\chocolatey\bin\python.exe', 'C:\Python313\python.exe')
        }
        Find-Executable -Name 'python' | Should -Be 'C:\ProgramData\chocolatey\bin\python.exe'
    }
    It 'ignores the INFO line where.exe emits when nothing matches' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine {
            'INFO: Could not find files for the given pattern(s).'
        }
        Find-Executable -Name 'nosuchtool' | Should -BeNullOrEmpty
    }
    It 'returns null when the command does not resolve' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { throw 'not found' }
        Find-Executable -Name 'nosuchtool' | Should -BeNullOrEmpty
    }
}

Describe 'Find-X64dbgRoot' {
    It 'prefers a known install path over PATH' {
        Mock -ModuleName ReAgent.Discovery Test-Path {
            $LiteralPath -eq 'C:\Tools\x64dbg\release\x64\x64dbg.exe'
        }
        Mock -ModuleName ReAgent.Discovery Find-Executable { 'C:\somewhere\else\x64dbg.exe' }
        Find-X64dbgRoot | Should -Be 'C:\Tools\x64dbg\release'
    }

    It 'refuses the Chocolatey shim, which resolves to the wrong root' {
        # where.exe returns C:\ProgramData\chocolatey\bin\x64dbg.exe. Two
        # Split-Path -Parent off that yields C:\ProgramData\chocolatey.
        Mock -ModuleName ReAgent.Discovery Test-Path { $false }
        Mock -ModuleName ReAgent.Discovery Find-Executable {
            'C:\ProgramData\chocolatey\bin\x64dbg.exe'
        }
        Find-X64dbgRoot | Should -BeNullOrEmpty
    }

    It 'falls back to a non-shim PATH hit' {
        Mock -ModuleName ReAgent.Discovery Test-Path { $false }
        Mock -ModuleName ReAgent.Discovery Find-Executable { 'D:\re\x64dbg\release\x64\x64dbg.exe' }
        Find-X64dbgRoot | Should -Be 'D:\re\x64dbg\release'
    }

    It 'returns null when x64dbg is absent' {
        Mock -ModuleName ReAgent.Discovery Test-Path { $false }
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Find-X64dbgRoot | Should -BeNullOrEmpty
    }
}

Describe 'Get-GhidraVersion' {
    It 'reads the version out of the install directory name' {
        Get-GhidraVersion -GhidraRoot 'C:\x\ghidra_12.1.2_PUBLIC' | Should -Be ([version]'12.1.2')
    }
    It 'accepts a two-component version' {
        Get-GhidraVersion -GhidraRoot 'C:\x\ghidra_12.1_PUBLIC' | Should -Be ([version]'12.1')
    }
    It 'returns null for a directory that does not carry a version' {
        Get-GhidraVersion -GhidraRoot 'C:\Tools\ghidra' | Should -BeNullOrEmpty
    }
}

Describe 'Find-CdbPath' {
    It 'finds cdb inside the WinDbg MSIX package, which is not on PATH' {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Get-AppxInstallLocation {
            'C:\Program Files\WindowsApps\Microsoft.WinDbg_1.2606.22001.0_x64__8wekyb3d8bbwe'
        }
        Mock -ModuleName ReAgent.Discovery Test-Path { $true }
        Find-CdbPath | Should -BeLike '*Microsoft.WinDbg*\amd64\cdb.exe'
    }

    It 'prefers a PATH hit when one exists' {
        Mock -ModuleName ReAgent.Discovery Find-Executable { 'C:\Kits\cdb.exe' }
        Find-CdbPath | Should -Be 'C:\Kits\cdb.exe'
    }

    It 'returns null when neither PATH nor the MSIX package has it' {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Get-AppxInstallLocation { $null }
        Mock -ModuleName ReAgent.Discovery Test-Path { $false }
        Find-CdbPath | Should -BeNullOrEmpty
    }
}

Describe 'Test-BinaryNinjaMcpCapable' {
    It 'reports capable when the binary carries the ui.mcp.enabled setting' {
        Mock -ModuleName ReAgent.Discovery Test-Path { $true }
        Mock -ModuleName ReAgent.Discovery Test-FileContainsAscii { $true }
        Test-BinaryNinjaMcpCapable -BinaryNinjaRoot 'C:\Program Files\Vector35\BinaryNinja' |
            Should -BeTrue
    }

    It 'reports not capable for a Binary Ninja too old to have the setting' {
        Mock -ModuleName ReAgent.Discovery Test-Path { $true }
        Mock -ModuleName ReAgent.Discovery Test-FileContainsAscii { $false }
        Test-BinaryNinjaMcpCapable -BinaryNinjaRoot 'C:\old\BinaryNinja' | Should -BeFalse
    }

    It 'reports not capable when Binary Ninja is absent' {
        Test-BinaryNinjaMcpCapable -BinaryNinjaRoot $null | Should -BeFalse
    }
}

Describe 'Get-HostInventory' {
    BeforeEach {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Find-X64dbgRoot { $null }
        Mock -ModuleName ReAgent.Discovery Find-GhidraRoot { $null }
        Mock -ModuleName ReAgent.Discovery Find-BinaryNinjaRoot { $null }
        Mock -ModuleName ReAgent.Discovery Find-CdbPath { $null }
        Mock -ModuleName ReAgent.Discovery Get-MachineFact {
            [PSCustomObject]@{ FreeDiskGb = 120; TotalRamGb = 32
                IsVirtualMachine = $true; IsAdministrator = $true
            }
        }
    }

    It 'returns an object with every documented property even when nothing is installed' {
        $inv = Get-HostInventory
        foreach ($p in @('Python', 'PythonVersion', 'Jdk', 'JdkVersion', 'Cdb', 'Uv',
                'X64dbgRoot', 'GhidraRoot', 'GhidraVersion', 'BinaryNinjaRoot',
                'BinaryNinjaSettingsPath', 'BinaryNinjaMcpCapable', 'ClaudeCode',
                'FreeDiskGb', 'TotalRamGb', 'IsVirtualMachine', 'IsAdministrator')) {
            $inv.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'reports missing tools as null rather than throwing' {
        $inv = Get-HostInventory
        $inv.X64dbgRoot | Should -BeNullOrEmpty
        $inv.Cdb | Should -BeNullOrEmpty
        $inv.TotalRamGb | Should -Be 32
    }

    It 'always resolves a Binary Ninja settings path, even with no Binary Ninja' {
        (Get-HostInventory).BinaryNinjaSettingsPath | Should -BeLike '*Binary Ninja*settings.json'
    }
}

Describe 'Get-JavaVersion' {
    It 'parses a modern single-component JDK version' {
        # [version] rejects a bare '25' - it needs at least major.minor. Before
        # the pad, this returned $null and the inventory reported no JDK at all
        # on a host that plainly had one.
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine {
            'openjdk version "25" 2025-09-16'
        }
        Get-JavaVersion -JavaPath 'java.exe' | Should -Be ([version]'25.0')
    }

    It 'parses a legacy 1.8 style version' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine {
            'java version "1.8.0_401"'
        }
        Get-JavaVersion -JavaPath 'java.exe' | Should -Be ([version]'1.8.0')
    }

    It 'parses a three-component version' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine {
            'openjdk version "21.0.5" 2024-10-15'
        }
        Get-JavaVersion -JavaPath 'java.exe' | Should -Be ([version]'21.0.5')
    }

    It 'returns null when java cannot be run' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { throw 'nope' }
        Get-JavaVersion -JavaPath 'java.exe' | Should -BeNullOrEmpty
    }
}

Describe 'Test-Preflight' {
    BeforeAll {
        function Get-TestInv {
            param($Admin = $true, $Vm = $true, $Claude = 'C:\claude.exe',
                $Ram = 32, $Disk = 100)
            [PSCustomObject]@{
                IsAdministrator = $Admin; IsVirtualMachine = $Vm; ClaudeCode = $Claude
                TotalRamGb      = $Ram; FreeDiskGb = $Disk
            }
        }
    }

    BeforeEach {
        Mock -ModuleName ReAgent.Discovery Test-NetworkReachable { $true }
    }

    It 'returns no blockers on a healthy host' {
        Test-Preflight -Inventory (Get-TestInv) | Should -BeNullOrEmpty
    }

    It 'blocks when not elevated' {
        (Test-Preflight -Inventory (Get-TestInv -Admin $false)) -join ';' |
            Should -BeLike '*Administrator*'
    }

    It 'blocks when Claude Code is absent' {
        (Test-Preflight -Inventory (Get-TestInv -Claude $null)) -join ';' |
            Should -BeLike '*Claude Code*'
    }

    It 'blocks when not on a virtual machine' {
        (Test-Preflight -Inventory (Get-TestInv -Vm $false)) -join ';' |
            Should -BeLike '*virtual machine*'
    }

    It 'blocks when there is no network' {
        Mock -ModuleName ReAgent.Discovery Test-NetworkReachable { $false }
        (Test-Preflight -Inventory (Get-TestInv)) -join ';' | Should -BeLike '*network*'
    }

    It 'reports every blocker at once rather than only the first' {
        @(Test-Preflight -Inventory (Get-TestInv -Admin $false -Claude $null)).Count |
            Should -Be 2
    }

    It 'does NOT block on low RAM - that is a warning, not a blocker' {
        # This host has 8 GB against a 32 GB advisory. Blocking would make the
        # installer unusable on the very box it was written for.
        Test-Preflight -Inventory (Get-TestInv -Ram 8) | Should -BeNullOrEmpty
    }

    It 'every blocker message tells the operator what to do about it' {
        $b = Test-Preflight -Inventory (Get-TestInv -Admin $false -Vm $false -Claude $null)
        foreach ($m in $b) { $m.Length | Should -BeGreaterThan 40 }
    }
}

Describe 'Get-PreflightWarning' {
    It 'warns below the recommended RAM' {
        $inv = [PSCustomObject]@{ TotalRamGb = 8; FreeDiskGb = 100 }
        (Get-PreflightWarning -Inventory $inv) -join ';' | Should -BeLike '*RAM*'
    }

    It 'warns on low free disk' {
        $inv = [PSCustomObject]@{ TotalRamGb = 32; FreeDiskGb = 5 }
        (Get-PreflightWarning -Inventory $inv) -join ';' | Should -BeLike '*disk*'
    }

    It 'says nothing about a comfortable host' {
        $inv = [PSCustomObject]@{ TotalRamGb = 64; FreeDiskGb = 500 }
        Get-PreflightWarning -Inventory $inv | Should -BeNullOrEmpty
    }
}

Describe 'Assert-Preflight' {
    BeforeEach {
        Mock -ModuleName ReAgent.Discovery Test-NetworkReachable { $true }
    }

    It 'throws listing the blockers' {
        $inv = [PSCustomObject]@{
            IsAdministrator = $false; IsVirtualMachine = $true; ClaudeCode = 'x'
            TotalRamGb      = 32; FreeDiskGb = 100
        }
        { Assert-Preflight -Inventory $inv } | Should -Throw '*Administrator*'
    }

    It 'does not throw on a healthy host' {
        $inv = [PSCustomObject]@{
            IsAdministrator = $true; IsVirtualMachine = $true; ClaudeCode = 'x'
            TotalRamGb      = 32; FreeDiskGb = 100
        }
        { Assert-Preflight -Inventory $inv } | Should -Not -Throw
    }
}

Describe 'Assert-Preflight empty-array handling' {
    It 'treats no blockers as success rather than a null dereference' {
        # Regression: Test-Preflight returns @(), PowerShell unrolls it to $null
        # on return, and $null.Count throws under Set-StrictMode -Version Latest.
        Mock -ModuleName ReAgent.Discovery Test-Preflight { @() }
        { Assert-Preflight -Inventory ([PSCustomObject]@{}) } | Should -Not -Throw
    }
}

Describe 'Get-PreflightWarning with no inventory' {
    It 'returns no warnings rather than throwing' {
        # It runs unconditionally after the phase loop, including on a run where
        # preflight was skipped or aborted, so a null inventory must be survivable.
        @(Get-PreflightWarning -Inventory $null).Count | Should -Be 0
    }
}

Describe 'Test-Preflight under -VerifyOnly' {
    BeforeEach {
        Mock -ModuleName ReAgent.Discovery Test-NetworkReachable { $true }
    }

    It 'does not block an unelevated verification run' {
        # Elevation, egress and the VM check exist because installing needs
        # them. Verifying installs nothing, and refusing to report on a healthy
        # box because the shell is unelevated helps nobody.
        $inv = [PSCustomObject]@{
            IsAdministrator = $false; IsVirtualMachine = $true
            ClaudeCode      = 'C:\claude.exe'; TotalRamGb = 32; FreeDiskGb = 100
        }
        Test-Preflight -Inventory $inv | Should -Not -BeNullOrEmpty
        Test-Preflight -Inventory $inv -VerifyOnly | Should -BeNullOrEmpty
    }

    It 'still blocks when Claude Code is absent' {
        # Nothing downstream means anything without it, verification included.
        $inv = [PSCustomObject]@{
            IsAdministrator = $true; IsVirtualMachine = $true
            ClaudeCode      = $null; TotalRamGb = 32; FreeDiskGb = 100
        }
        (Test-Preflight -Inventory $inv -VerifyOnly) -join ';' | Should -BeLike '*Claude Code*'
    }

    It 'does not block a verification run that is offline' {
        Mock -ModuleName ReAgent.Discovery Test-NetworkReachable { $false }
        $inv = [PSCustomObject]@{
            IsAdministrator = $true; IsVirtualMachine = $true
            ClaudeCode      = 'C:\claude.exe'; TotalRamGb = 32; FreeDiskGb = 100
        }
        Test-Preflight -Inventory $inv -VerifyOnly | Should -BeNullOrEmpty
    }
}
