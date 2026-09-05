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
