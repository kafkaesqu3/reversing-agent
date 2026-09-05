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
