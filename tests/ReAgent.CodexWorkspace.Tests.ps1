BeforeAll {
    # Earlier suites can retain nested instances under different UNC path spellings.
    Get-Module ReAgent.CodexWorkspace -All | Remove-Module -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexAdapter.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexWorkspace.psm1"

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

Describe 'Install-CodexSkillDirectory' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $candidate = [pscustomobject]@{
            Name = 'crash'; Destination = (Join-Path $root 'crash'); Marker = 'codex:windbg/crash'
            Files = @(
                [pscustomobject]@{ RelativePath = 'SKILL.md'; Bytes = [byte[]]@(65, 10) }
                [pscustomobject]@{ RelativePath = '.re-agent-managed'
                    Bytes = [Text.Encoding]::UTF8.GetBytes('codex:windbg/crash') }
            )
        }
    }

    It 'preserves unchanged tree timestamps and removes stale files on replacement' {
        $first = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $before = (Get-Item $candidate.Destination).LastWriteTimeUtc
        $again = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $again.Changed | Should -BeFalse
        $again.Sha256 | Should -Be $first.Sha256
        (Get-Item $candidate.Destination).LastWriteTimeUtc | Should -Be $before
        'old' | Set-Content (Join-Path $candidate.Destination 'obsolete.md')
        $changed = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $changed.Changed | Should -BeTrue
        Test-Path (Join-Path $candidate.Destination 'obsolete.md') | Should -BeFalse
        @(Get-ChildItem $root -Directory).Count | Should -Be 1
    }

    It 'recovers a lone previous tree before comparing an unchanged candidate' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $previous = Join-Path $root '.re-agent-previous-crash-0123456789abcdef0123456789abcdef'
        Move-Item $candidate.Destination $previous
        $result = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $result.Changed | Should -BeFalse
        Test-Path $candidate.Destination | Should -BeTrue
        Test-Path $previous | Should -BeFalse
    }

    It 'restores the prior tree when publishing the staged directory throws' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $candidate.Files[0].Bytes = [byte[]]@(66, 10)
        Mock Move-Item -ModuleName ReAgent.CodexWorkspace {
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath `
                -Destination $Destination -ErrorAction Stop
        }
        Mock Move-Item -ModuleName ReAgent.CodexWorkspace {
            throw 'injected publish failure'
        } -ParameterFilter { $LiteralPath -like '*\.re-agent-stage-*' }
        { Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root } |
            Should -Throw '*injected*'
        [IO.File]::ReadAllBytes((Join-Path $candidate.Destination 'SKILL.md')) -join ',' |
            Should -Be '65,10'
        @(Get-ChildItem $root -Directory).Count | Should -Be 1
    }

    It 'refuses an unmanaged collision and creates no stage' {
        $null = New-Item -ItemType Directory $candidate.Destination -Force
        'personal' | Set-Content (Join-Path $candidate.Destination 'SKILL.md')
        { Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root } |
            Should -Throw '*unmanaged*'
        @(Get-ChildItem $root -Directory).Count | Should -Be 1
    }

    It 'does not create roots or recovery artifacts for WhatIf' {
        $result = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root -WhatIf
        $result.Status | Should -Be 'what-if'
        Test-Path $root | Should -BeFalse
    }

    It 'rejects file paths that escape the candidate directory' {
        $candidate.Files[0].RelativePath = '..\outside.txt'
        { Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root } |
            Should -Throw '*Unsafe*path*'
        Test-Path $root | Should -BeFalse
    }

    It 'refuses replacement when an existing tree contains an empty directory junction' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $outside = Join-Path $TestDrive 'junction-target'
        $null = New-Item -ItemType Directory $outside -Force
        $link = Join-Path $candidate.Destination 'linked'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        $candidate.Files[0].Bytes = [byte[]]@(66, 10)
        try {
            { Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root } |
                Should -Throw '*reparse point*'
            [IO.File]::ReadAllBytes((Join-Path $candidate.Destination 'SKILL.md')) -join ',' |
                Should -Be '65,10'
        } finally {
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        }
    }
}

Describe 'New-CodexSkillCandidate validation' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../src/ReAgent.Skills.psm1" -Force
    }
    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $source = Join-Path $repo 'vendor\skills\windbg\crash'
        $null = New-Item -ItemType Directory $source -Force
        "---`nname: crash`n---`nUse the debugger." | Set-Content (Join-Path $source 'SKILL.md')
        $skill = [pscustomobject]@{ name = 'crash'; upstream = 'upstream'; enabled = $true }
        $pack = [pscustomobject]@{ namespace = 'windbg'; skills = @($skill)
            scanExceptions = @(); codexScanExceptions = @() }
        $params = @{ Source = $source; Destination = (Join-Path $repo '.agents\skills\crash')
            Pack = $pack; Skill = $skill; Catalog = Get-ToolCatalog
            Config = [pscustomobject]@{ mcpServers = @(
                [pscustomobject]@{ name = 'mcp-windbg'; transport = 'http' },
                [pscustomobject]@{ name = 'pdbsql'; transport = 'sse' }) } }
    }

    It 'rejects unwaived Claude residue in quoted history' {
        '> TodoWrite' | Set-Content (Join-Path $source 'reference.md')
        { New-CodexSkillCandidate @params } | Should -Throw '*C4-TODOWRITE*reference.md*'
        Test-Path (Split-Path $params.Destination) | Should -BeFalse
    }

    It 'uses the exact configured exception for real upstream dispatch history' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $config = Get-Content (Join-Path $repoRoot 're-agent.config.json') -Raw |
            ConvertFrom-Json
        $realPack = $config.skills | Where-Object namespace -EQ 'arch'
        $realSkill = $realPack.skills | Where-Object enabled
        $sourcePath = Join-Path $repoRoot 'vendor\skills\arch\arch-architectural-analysis'
        $arguments = @{ Source = $sourcePath
            Destination = (Join-Path $TestDrive 'real\.agents\skills\arch-architectural-analysis')
            Pack = $realPack; Skill = $realSkill; Config = $config; Catalog = Get-ToolCatalog }
        { New-CodexSkillCandidate @arguments } | Should -Not -Throw
        $realPack.codexScanExceptions = @()
        { New-CodexSkillCandidate @arguments } |
            Should -Throw '*C4-AGENT-TOOL*references/subagent-dispatch.md*'
    }

    It 'does not mistake sub-agent tool access prose for the Claude Agent tool' {
        'Sub-agent tool access depends on configuration.' |
            Set-Content (Join-Path $source 'reference.md')
        { New-CodexSkillCandidate @params } | Should -Not -Throw
    }

    It 'waives only an exact skill file rule triple' {
        '> TodoWrite' | Set-Content (Join-Path $source 'reference.md')
        $exception = [pscustomobject]@{ skill = 'upstream'; file = 'reference.md'
            ruleId = 'C4-TODOWRITE'; justification = 'Quoted upstream history.' }
        $pack.codexScanExceptions = @($exception)
        { New-CodexSkillCandidate @params } | Should -Not -Throw
        foreach ($field in @('skill', 'file', 'ruleId')) {
            $old = $exception.$field
            $exception.$field = 'wrong'
            { New-CodexSkillCandidate @params } | Should -Throw '*C4-TODOWRITE*'
            $exception.$field = $old
        }
    }

    It 'rejects SSE references even when allowed-tools would be removed' {
        "---`nname: crash`nallowed-tools: mcp__pdbsql__pdb_query`n---`nBody" |
            Set-Content (Join-Path $source 'SKILL.md')
        { New-CodexSkillCandidate @params } | Should -Throw '*unsupported*'
    }

    It 'rejects unknown MCP references in supporting text' {
        'mcp__missing__read' | Set-Content (Join-Path $source 'reference.json')
        { New-CodexSkillCandidate @params } | Should -Throw '*unknown*'
    }

    It 'rejects a mismatched frontmatter name before creating a destination' {
        "---`nname: other`n---`nBody" | Set-Content (Join-Path $source 'SKILL.md')
        { New-CodexSkillCandidate @params } | Should -Throw '*frontmatter name*'
        Test-Path (Split-Path $params.Destination) | Should -BeFalse
    }

    It 'rejects a source outside the reviewed vendor tree' {
        $params.Source = $repo
        { New-CodexSkillCandidate @params } | Should -Throw '*vendor/skills*'
    }

    It 'refuses unmanaged Codex collisions while preparing the candidate' {
        $null = New-Item -ItemType Directory $params.Destination -Force
        'personal' | Set-Content (Join-Path $params.Destination 'SKILL.md')
        { New-CodexSkillCandidate @params } | Should -Throw '*unmanaged*'
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

    It 'stops rather than recreating a deliberately disabled expected skill' {
        $root = Join-Path (Join-Path $PSScriptRoot '..') 'templates'
        $text = New-ClientInstructionText -TemplateRoot $root -Client Codex

        $text | Should -Match (
            '(?s)skill you expect and cannot find.*disabled deliberately.*' +
            'disabledReason in re-agent\.config\.json')
        $text | Should -BeLike '*Do not reimplement it by hand*'
        $text | Should -Match '(?s)do not work\s+around its absence silently'
        $text | Should -BeLike '*say which capability is missing and why you stopped*'
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

    It 'rejects a case-changed marker-only collision without changing it' {
        $root = Join-Path $TestDrive 'case-changed'
        $null = New-Item -ItemType Directory -Path $root
        $path = Join-Path $root 'AGENTS.md'
        Write-TestUtf8File -Path $path -Text $script:ManagedMarker.ToUpperInvariant()
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

    It 'rejects a case-changed marker before WhatIf can bypass ownership' {
        $root = Join-Path $TestDrive 'case-changed-what-if'
        $null = New-Item -ItemType Directory -Path $root
        $path = Join-Path $root 'AGENTS.md'
        Write-TestUtf8File -Path $path -Text $script:ManagedMarker.ToUpperInvariant()
        $beforeHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $beforeBytes = [IO.File]::ReadAllBytes($path)
        $candidate = "$script:ManagedMarker`n# replacement`n"

        { Set-ManagedTextFile -Path $path -Text $candidate `
                -Marker $script:ManagedMarker -BackupOnChange $true -WhatIf } |
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
