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
