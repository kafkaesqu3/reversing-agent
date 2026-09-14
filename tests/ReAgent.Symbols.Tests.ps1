BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
}

Describe 'Get-SymbolPathValue' {
    It 'builds the SRV triple in the order the debugger expects' {
        Get-SymbolPathValue -CacheDir 'C:\re\symbols' `
            -Server 'https://msdl.microsoft.com/download/symbols' |
            Should -Be 'SRV*C:\re\symbols*https://msdl.microsoft.com/download/symbols'
    }
}

Describe 'Invoke-SymbolPrewarm' {
    BeforeAll {
        $Script:Cfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{ symbolCache = 'C:\re\symbols' }
            symbols = [PSCustomObject]@{
                server  = 'https://msdl.microsoft.com/download/symbols'
                prewarm = @('ntdll.dll')
            }
        }
    }

    It 'warns and returns rather than failing when symchk is absent' {
        # symchk is NOT in the WinDbg MSIX package and is absent from a stock
        # FLARE VM. Phase 2 must not fail because of it.
        Mock -ModuleName ReAgent.Symbols Find-Executable { $null }
        Mock -ModuleName ReAgent.Symbols Invoke-CommandLine { }
        { Invoke-SymbolPrewarm -Config $Script:Cfg -SymbolPath 'SRV*x*y' } | Should -Not -Throw
        Should -Invoke -ModuleName ReAgent.Symbols Invoke-CommandLine -Times 0 -Exactly
    }

    It 'runs symchk for each prewarm target when symchk exists' {
        Mock -ModuleName ReAgent.Symbols Find-Executable { 'C:\symchk.exe' }
        Mock -ModuleName ReAgent.Symbols Invoke-CommandLine { }
        Invoke-SymbolPrewarm -Config $Script:Cfg -SymbolPath 'SRV*x*y'
        Should -Invoke -ModuleName ReAgent.Symbols Invoke-CommandLine -Times 1 -Exactly
    }

    It 'keeps going when one target fails' {
        Mock -ModuleName ReAgent.Symbols Find-Executable { 'C:\symchk.exe' }
        Mock -ModuleName ReAgent.Symbols Invoke-CommandLine { throw 'download failed' }
        { Invoke-SymbolPrewarm -Config $Script:Cfg -SymbolPath 'SRV*x*y' } | Should -Not -Throw
    }
}

Describe 'Test-SymbolsReady' {
    BeforeAll {
        $Script:ReadyCfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{ symbolCache = 'C:\re\symbols' }
            symbols = [PSCustomObject]@{ server = 'https://example/symbols' }
        }
    }

    It 'is false when the machine variable does not match' {
        Mock -ModuleName ReAgent.Symbols Get-MachineSymbolPath { 'something else' }
        Test-SymbolsReady -Config $Script:ReadyCfg | Should -BeFalse
    }

    It 'is false when the variable matches but the cache directory is missing' {
        Mock -ModuleName ReAgent.Symbols Get-MachineSymbolPath {
            'SRV*C:\re\symbols*https://example/symbols'
        }
        Mock -ModuleName ReAgent.Symbols Test-Path { $false }
        Test-SymbolsReady -Config $Script:ReadyCfg | Should -BeFalse
    }

    It 'is true on the variable and the directory alone - an empty cache is fine' {
        Mock -ModuleName ReAgent.Symbols Get-MachineSymbolPath {
            'SRV*C:\re\symbols*https://example/symbols'
        }
        Mock -ModuleName ReAgent.Symbols Test-Path { $true }
        Test-SymbolsReady -Config $Script:ReadyCfg | Should -BeTrue
    }
}

Describe 'Resolve-PdbPath' {
    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("sym-" + [guid]::NewGuid())
        $guid = Join-Path $script:Root 'ntdll.pdb\1DF9DB46D55D6B869568C9F6E9287DE41'
        New-Item -ItemType Directory -Path $guid -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $guid 'ntdll.pdb') -Value 'fake' -Encoding Ascii
    }
    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'walks the GUID directory to the real file' {
        $p = Resolve-PdbPath -SymbolRoot $script:Root -Module 'ntdll'
        (Test-Path -LiteralPath $p -PathType Leaf) | Should -BeTrue
        $p | Should -BeLike '*1DF9DB46D55D6B869568C9F6E9287DE41\ntdll.pdb'
    }

    It 'never returns the container directory' {
        # The 0x806D0005 trap: '<root>\ntdll.pdb' exists and is a directory.
        $p = Resolve-PdbPath -SymbolRoot $script:Root -Module 'ntdll'
        $p | Should -Not -Be (Join-Path $script:Root 'ntdll.pdb')
    }

    It 'returns null for a module the cache has never warmed' {
        Resolve-PdbPath -SymbolRoot $script:Root -Module 'kernel32' | Should -BeNullOrEmpty
    }
}

Describe 'Test-PdbPathCheck (Q1)' {
    BeforeAll {
        $script:Root2 = Join-Path ([IO.Path]::GetTempPath()) ("sym-" + [guid]::NewGuid())
        $guid = Join-Path $script:Root2 'ntdll.pdb\AAAA1'
        New-Item -ItemType Directory -Path $guid -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $guid 'ntdll.pdb') -Value 'fake' -Encoding Ascii
    }
    AfterAll { Remove-Item -LiteralPath $script:Root2 -Recurse -Force -ErrorAction SilentlyContinue }

    It 'passes when the module resolves to a file' {
        $srv = [PSCustomObject]@{ name = 'pdbsql'
            pdb = [PSCustomObject]@{ module = 'ntdll' } }
        Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2 | Should -BeNullOrEmpty
    }

    It 'fails Q1 naming 0x806D0005 when the module is not in the cache' {
        $srv = [PSCustomObject]@{ name = 'pdbsql'
            pdb = [PSCustomObject]@{ module = 'nosuch' } }
        $f = Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2
        @($f).Count | Should -Be 1
        $f[0].Check | Should -Be 'Q1'
        $f[0].Message | Should -BeLike '*0x806D0005*'
    }

    It 'returns nothing for a server with no pdb block' {
        $srv = [PSCustomObject]@{ name = 'ghidrasql' }
        Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2 | Should -BeNullOrEmpty
    }
}

