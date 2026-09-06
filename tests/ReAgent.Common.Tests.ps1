BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
}

Describe 'New-PhaseResult' {
    It 'returns an object carrying every field it was given' {
        $r = New-PhaseResult -Id 3 -Name 'McpServers' -Status 'ok' -DurationMs 1200
        $r.Id | Should -Be 3
        $r.Name | Should -Be 'McpServers'
        $r.Status | Should -Be 'ok'
        $r.DurationMs | Should -Be 1200
    }

    It 'rejects a status outside the known set' {
        # Matching the message matters: a bare -Throw also passes when the
        # function does not exist at all, which is how this test passed
        # against an empty module.
        { New-PhaseResult -Id 1 -Name 'X' -Status 'banana' -DurationMs 0 } |
            Should -Throw '*banana*'
    }
}

Describe 'Get-ReAgentExitCode' {
    It 'returns 0 when every phase succeeded' {
        $p = @(
            (New-PhaseResult -Id 0 -Name 'A' -Status 'ok' -DurationMs 1),
            (New-PhaseResult -Id 1 -Name 'B' -Status 'skipped' -DurationMs 1)
        )
        Get-ReAgentExitCode -PhaseResults $p | Should -Be 0
    }

    It 'returns 1 when a phase failed but none aborted' {
        $p = @(
            (New-PhaseResult -Id 0 -Name 'A' -Status 'ok' -DurationMs 1),
            (New-PhaseResult -Id 1 -Name 'B' -Status 'failed' -DurationMs 1)
        )
        Get-ReAgentExitCode -PhaseResults $p | Should -Be 1
    }

    It 'returns 2 when a phase aborted' {
        $p = @( (New-PhaseResult -Id 0 -Name 'A' -Status 'aborted' -DurationMs 1) )
        Get-ReAgentExitCode -PhaseResults $p | Should -Be 2
    }
}

Describe 'Invoke-Phase' {
    It 'skips a phase whose Test already passes' {
        # A hashtable, not a plain variable: the scriptblock closes over the
        # reference, so the mutation is visible here. $script:ran in an It block
        # writes to a different scope and would pass even if Fn had run.
        $state = @{ Ran = $false }
        $phase = @{
            Id   = 1; Name = 'Thing'
            Test = { $true }
            Fn   = { $state.Ran = $true }
        }
        $r = Invoke-Phase -Phase $phase -Context @{}
        $r.Status | Should -Be 'skipped'
        $state.Ran | Should -BeFalse
    }

    It 'runs a phase whose Test fails' {
        $state = @{ Ran = $false }
        $phase = @{
            Id   = 1; Name = 'Thing'
            Test = { $false }
            Fn   = { $state.Ran = $true }
        }
        (Invoke-Phase -Phase $phase -Context @{}).Status | Should -Be 'ok'
        $state.Ran | Should -BeTrue
    }

    It 'runs a passing phase anyway when -Force is given' {
        $state = @{ Ran = $false }
        $phase = @{ Id = 1; Name = 'Thing'; Test = { $true }; Fn = { $state.Ran = $true } }
        (Invoke-Phase -Phase $phase -Context @{} -Force).Status | Should -Be 'ok'
        $state.Ran | Should -BeTrue
    }

    It 'records a failure without throwing' {
        $phase = @{ Id = 1; Name = 'Thing'; Test = { $false }; Fn = { throw 'boom' } }
        $r = Invoke-Phase -Phase $phase -Context @{}
        $r.Status | Should -Be 'failed'
        $r.ErrorMessage | Should -BeLike '*boom*'
    }

    It 'treats a throwing Test as not-yet-satisfied rather than a failure' {
        $phase = @{ Id = 1; Name = 'Thing'; Test = { throw 'cannot tell' }; Fn = { 'done' } }
        (Invoke-Phase -Phase $phase -Context @{}).Status | Should -Be 'ok'
    }

    It 'passes the shared context to both blocks' {
        $phase = @{
            Id   = 1; Name = 'Thing'
            Test = { param($c) $c.AlreadyDone }
            Fn   = { param($c) $c.Touched = $true }
        }
        $ctx = @{ AlreadyDone = $false }
        Invoke-Phase -Phase $phase -Context $ctx | Out-Null
        $ctx.Touched | Should -BeTrue
    }

    It 'always records a duration' {
        $phase = @{
            Id   = 1; Name = 'Thing'; Test = { $false }
            Fn   = { Start-Sleep -Milliseconds 10 }
        }
        (Invoke-Phase -Phase $phase -Context @{}).DurationMs | Should -BeGreaterThan 0
    }

    It 'names the phase in the result so the manifest can report it' {
        $phase = @{ Id = 4; Name = 'AgentConfig'; Test = { $false }; Fn = { } }
        $r = Invoke-Phase -Phase $phase -Context @{}
        $r.Id | Should -Be 4
        $r.Name | Should -Be 'AgentConfig'
    }
}

Describe 'Select-Phase' {
    BeforeAll {
        $Script:Table = @(
            @{ Id = 0; Name = 'Preflight' }
            @{ Id = 1; Name = 'Prerequisites' }
            @{ Id = 2; Name = 'Symbols' }
            @{ Id = 3; Name = 'McpServers' }
            @{ Id = 4; Name = 'AgentConfig' }
            @{ Id = 5; Name = 'Verify' }
            @{ Id = 6; Name = 'Manifest' }
        )
    }

    It 'runs every phase by default' {
        (Select-Phase -PhaseTable $Script:Table).Count | Should -Be 7
    }

    It 'runs preflight under -VerifyOnly, so verification has an inventory' {
        # Without phase 0 every check degrades to "Not installed on this host" -
        # a confident false negative, which is worse than no report at all.
        $ids = @(Select-Phase -PhaseTable $Script:Table -VerifyOnly | ForEach-Object { $_.Id })
        $ids | Should -Be @(0, 5, 6)
    }

    It 'honours an explicit phase list' {
        @(Select-Phase -PhaseTable $Script:Table -Phases @(2, 4) |
            ForEach-Object { $_.Id }) | Should -Be @(2, 4)
    }

    It 'lets -VerifyOnly win over an explicit phase list' {
        @(Select-Phase -PhaseTable $Script:Table -VerifyOnly -Phases @(1) |
            ForEach-Object { $_.Id }) | Should -Be @(0, 5, 6)
    }
}

Describe 'Grant-PathFullControl' {
    It 'adds an inheritable ace, so files created later inherit it' {
        # manifest.json was created by the elevated run and inherited only
        # ProgramData's defaults - BUILTIN\Users ReadAndExecute - so the analyst
        # could not rewrite it and -VerifyOnly died on its last phase.
        $dir = Join-Path $TestDrive 'state-acl'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Grant-PathFullControl -Path $dir -Identity $env:USERNAME -Confirm:$false

        $ace = (Get-Acl $dir).Access |
            Where-Object { $_.IdentityReference -like "*\$env:USERNAME" -and -not $_.IsInherited }
        $ace | Should -Not -BeNullOrEmpty
        $ace.FileSystemRights | Should -Match 'FullControl'
        "$($ace.InheritanceFlags)" | Should -BeLike '*ObjectInherit*'
        "$($ace.InheritanceFlags)" | Should -BeLike '*ContainerInherit*'
    }

    It 'lets the identity rewrite a file created after the grant' {
        $dir = Join-Path $TestDrive 'state-acl-2'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Grant-PathFullControl -Path $dir -Identity $env:USERNAME -Confirm:$false
        $f = Join-Path $dir 'manifest.json'
        Write-Utf8NoBomFile -Path $f -Text '{}'
        { Write-Utf8NoBomFile -Path $f -Text '{"a":1}' } | Should -Not -Throw
    }

    It 'applies the ace to files that already exist' {
        # Adding an inheritable ace to a directory does not re-propagate to
        # children already in it: manifest.json kept ProgramData's defaults and
        # stayed unwritable long after the directory itself was fixed.
        $dir = Join-Path $TestDrive 'state-acl-3'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $existing = Join-Path $dir 'manifest.json'
        Set-Content -LiteralPath $existing -Value '{}' -Encoding ASCII

        Grant-PathFullControl -Path $dir -Identity $env:USERNAME -Confirm:$false

        $ace = (Get-Acl $existing).Access |
            Where-Object { $_.IdentityReference -like "*\$env:USERNAME" }
        $ace | Should -Not -BeNullOrEmpty
        "$($ace.FileSystemRights)" | Should -Match 'FullControl'
    }

    It 'warns rather than throwing when the path cannot be re-acled' {
        { Grant-PathFullControl -Path (Join-Path $TestDrive 'no-such-dir') `
                -Identity $env:USERNAME -Confirm:$false -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }
}
