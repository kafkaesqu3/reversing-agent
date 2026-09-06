BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Skills.psm1" -Force

    function Get-TestPack {
        param($Namespace = 'windbg', $Commit = ('a' * 40))
        [PSCustomObject]@{
            namespace = $Namespace; enabled = $true
            source = [PSCustomObject]@{ repo = 'svnscha/mcp-windbg'; commit = $Commit
                treeSha256 = 'PIN-ME'; subPath = 'skills' }
            review = [PSCustomObject]@{ reviewedBy = 'david'; reviewedAt = '2026-09-08'
                reviewedCommit = $Commit }
            targetServers = @('mcp-windbg'); scanExceptions = @(); skills = @()
        }
    }
}

Describe 'New-SkillResult' {
    It 'treats installed and skipped as installed, and nothing else' {
        (New-SkillResult -Pack (Get-TestPack) -Status 'installed').Installed | Should -BeTrue
        (New-SkillResult -Pack (Get-TestPack) -Status 'skipped').Installed | Should -BeTrue
        (New-SkillResult -Pack (Get-TestPack) -Status 'failed').Installed | Should -BeFalse
        (New-SkillResult -Pack (Get-TestPack) -Status 'not-installed').Installed |
            Should -BeFalse
    }

    It 'rejects an invalid status and names the offending value' {
        { New-SkillResult -Pack (Get-TestPack) -Status 'banana' } | Should -Throw '*banana*'
    }

    It 'carries provenance forward so the manifest can record it' {
        $r = New-SkillResult -Pack (Get-TestPack) -Status 'installed'
        $r.Repo | Should -Be 'svnscha/mcp-windbg'
        $r.Commit | Should -Be ('a' * 40)
        $r.ReviewedBy | Should -Be 'david'
    }
}
