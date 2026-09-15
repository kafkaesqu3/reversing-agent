BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexAdapter.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexWorkspace.psm1" -Force

    $script:ManagedMarker = '<!-- re-agent-managed: codex-operating-contract v1 -->'

    function Write-TestUtf8File {
        param([string]$Path, [string]$Text)

        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($Path, $Text, $encoding)
    }

    function Get-TestManagedSibling {
        param([string]$Path, [ValidateSet('pending', 'bak')][string]$Kind)

        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { return @() }
        $leaf = Split-Path -Leaf $Path
        return @(Get-ChildItem -LiteralPath $parent -File |
            Where-Object { $_.Name -like "$leaf.*.$Kind" })
    }
}

Describe 'New-ClientInstructionText' {
    It 'renders the Codex ownership and discovery contract' {
        $root = Join-Path (Join-Path $PSScriptRoot '..') 'templates'
        $text = New-ClientInstructionText -TemplateRoot $root -Client Codex

        $text | Should -Match '^<!-- re-agent-managed: codex-operating-contract v1 -->'
        $text | Should -BeLike '*.agents/skills*'
        $text | Should -BeLike '*.codex/agents*'
        $text | Should -BeLike '*$skill-name*'
    }

    It 'states every Codex legacy SSE limitation' {
        $root = Join-Path (Join-Path $PSScriptRoot '..') 'templates'
        $text = New-ClientInstructionText -TemplateRoot $root -Client Codex

        $text | Should -BeLike '*pdbsql*ghidrasql*legacy SSE*unavailable to Codex*'
        $text | Should -BeLike '*ghidramcp*disabled*legacy SSE*'
        $text | Should -BeLike '*x64dbg/x32dbg*target loaded*'
        $text | Should -BeLike '*Plugins > MCP > Start Server*application session*'
    }
}

Describe 'Set-ManagedTextFile' {
    It 'refuses an unmanaged collision without changing or staging anything' {
        $root = Join-Path $TestDrive 'unmanaged'
        $null = New-Item -ItemType Directory -Path $root
        $path = Join-Path $root 'AGENTS.md'
        Write-TestUtf8File -Path $path -Text '# operator-owned'
        $beforeHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $beforeBytes = [IO.File]::ReadAllBytes($path)
        $candidate = "$script:ManagedMarker`n# replacement`n"

        { Set-ManagedTextFile -Path $path -Text $candidate `
                -Marker $script:ManagedMarker -BackupOnChange $true } |
            Should -Throw '*unmanaged*'

        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $beforeHash
        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($beforeBytes -join ',')
        @(Get-TestManagedSibling -Path $path -Kind pending).Count | Should -Be 0
        @(Get-TestManagedSibling -Path $path -Kind bak).Count | Should -Be 0
    }

    It 'backs up and atomically updates a changed marked file' {
        $root = Join-Path $TestDrive 'updated'
        $null = New-Item -ItemType Directory -Path $root
        $path = Join-Path $root 'AGENTS.md'
        $old = "$script:ManagedMarker`n# old`n"
        $candidate = "$script:ManagedMarker`n# replacement`n"
        Write-TestUtf8File -Path $path -Text $old
        $oldBytes = [IO.File]::ReadAllBytes($path)
        $encoding = New-Object Text.UTF8Encoding($false)
        $candidateBytes = $encoding.GetBytes($candidate)

        $result = Set-ManagedTextFile -Path $path -Text $candidate `
            -Marker $script:ManagedMarker -BackupOnChange $true

        ([IO.File]::ReadAllBytes($path) -join ',') | Should -Be ($candidateBytes -join ',')
        $backups = @(Get-TestManagedSibling -Path $path -Kind bak)
        $backups.Count | Should -Be 1
        ([IO.File]::ReadAllBytes($backups[0].FullName) -join ',') |
            Should -Be ($oldBytes -join ',')
        $result.Status | Should -Be 'updated'
        $result.Changed | Should -BeTrue
        $result.Sha256 | Should -Be (
            Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        @(Get-TestManagedSibling -Path $path -Kind pending).Count | Should -Be 0
    }

    It 'preserves hash and timestamp when invoked twice with equal bytes' {
        $root = Join-Path $TestDrive 'unchanged'
        $null = New-Item -ItemType Directory -Path $root
        $path = Join-Path $root 'AGENTS.md'
        $candidate = "$script:ManagedMarker`n# stable`n"
        Write-TestUtf8File -Path $path -Text $candidate
        $beforeHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $beforeTime = (Get-Item -LiteralPath $path).LastWriteTimeUtc

        $first = Set-ManagedTextFile -Path $path -Text $candidate `
            -Marker $script:ManagedMarker -BackupOnChange $true
        $second = Set-ManagedTextFile -Path $path -Text $candidate `
            -Marker $script:ManagedMarker -BackupOnChange $true

        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $beforeHash
        (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should -Be $beforeTime
        @(Get-TestManagedSibling -Path $path -Kind bak).Count | Should -Be 0
        $first.Status | Should -Be 'unchanged'
        $second.Status | Should -Be 'unchanged'
        $second.Changed | Should -BeFalse
    }
}

Describe 'Write-CodexInstruction' {
    It 'renders WhatIf without creating the absent project or siblings' {
        $root = Join-Path $TestDrive 'what-if-project'
        $path = Join-Path $root 'AGENTS.md'
        $config = [PSCustomObject]@{
            paths = [PSCustomObject]@{ agentRoot = $root }
            CodexHome = Join-Path $TestDrive 'unrelated-codex-home'
        }
        $templateRoot = Join-Path (Join-Path $PSScriptRoot '..') 'templates'

        $result = Write-CodexInstruction -Config $config `
            -TemplateRoot $templateRoot -WhatIf

        Test-Path -LiteralPath $root | Should -BeFalse
        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath $config.CodexHome | Should -BeFalse
        @(Get-TestManagedSibling -Path $path -Kind pending).Count | Should -Be 0
        @(Get-TestManagedSibling -Path $path -Kind bak).Count | Should -Be 0
        $result.Path | Should -Be $path
        $result.Status | Should -Be 'what-if'
        $result.Changed | Should -BeTrue
    }
}
