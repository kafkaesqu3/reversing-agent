BeforeAll {
    # Earlier suites can retain nested instances under different UNC path spellings.
    Get-Module ReAgent.CodexWorkspace -All | Remove-Module -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Agents.psm1" -Force
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
        $script:candidate = [pscustomobject]@{
            Name = 'crash'; Destination = (Join-Path $root 'crash'); Marker = 'codex:windbg/crash'
            Files = @(
                [pscustomobject]@{ RelativePath = 'SKILL.md'; Bytes = [byte[]]@(65, 10) }
                [pscustomobject]@{ RelativePath = '.re-agent-managed'
                    Bytes = [Text.Encoding]::UTF8.GetBytes('codex:windbg/crash') }
            )
        }
    }

    It 'preserves unchanged tree timestamps and removes stale files on replacement' {
        $first = Install-CodexSkillDirectory -Candidate $script:candidate -SkillRoot $root
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

    It 'recovers before-publication interruption and removes owned abandoned stages' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $previous = Join-Path $root ('.re-agent-previous-crash-' + ('a' * 32))
        $stage = Join-Path $root ('.re-agent-stage-crash-' + ('b' * 32))
        Move-Item $candidate.Destination $previous
        $null = New-Item -ItemType Directory $stage
        $candidate.Marker | Set-Content (Join-Path $stage '.re-agent-stage-owner')
        'partial copy' | Set-Content (Join-Path $stage 'unfinished.md')
        $result = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $result.Changed | Should -BeFalse
        Test-Path (Join-Path $candidate.Destination 'SKILL.md') | Should -BeTrue
        Test-Path $previous | Should -BeFalse
        Test-Path $stage | Should -BeFalse
    }

    It 'cleans owned after-publication artifacts but preserves unowned siblings' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $before = (Get-Item $candidate.Destination).LastWriteTimeUtc
        $owned = @('previous-a', 'previous-b', 'stage-c') | ForEach-Object {
            $kind, $id = $_ -split '-'
            $path = Join-Path $root (".re-agent-$kind-crash-" + ($id * 32))
            Copy-Item $candidate.Destination $path -Recurse
            $path
        }
        $unowned = @('previous-d', 'stage-e') | ForEach-Object {
            $kind, $id = $_ -split '-'
            $path = Join-Path $root (".re-agent-$kind-crash-" + ($id * 32))
            $null = New-Item -ItemType Directory $path
            'codex:someone/else' | Set-Content (Join-Path $path '.re-agent-managed')
            'personal' | Set-Content (Join-Path $path '.re-agent-stage-owner')
            $path
        }
        $result = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $result.Changed | Should -BeFalse
        (Get-Item $candidate.Destination).LastWriteTimeUtc | Should -Be $before
        foreach ($path in $owned) { Test-Path $path | Should -BeFalse }
        foreach ($path in $unowned) { Test-Path $path | Should -BeTrue }
    }

    It 'converges after repeated interruptions leave multiple owned previous trees' {
        $null = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $older = Join-Path $root ('.re-agent-previous-crash-' + ('a' * 32))
        $newer = Join-Path $root ('.re-agent-previous-crash-' + ('b' * 32))
        Copy-Item $candidate.Destination $older -Recurse
        Move-Item $candidate.Destination $newer
        $result = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $root
        $result.Changed | Should -BeFalse
        @(Get-ChildItem $root -Directory).Name | Should -Be 'crash'
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
        $script:params = @{ Source = $source; Destination = (Join-Path $repo '.agents\skills\crash')
            Pack = $pack; Skill = $skill; Catalog = Get-ToolCatalog
            Config = [pscustomobject]@{ mcpServers = @(
                [pscustomobject]@{ name = 'mcp-windbg'; transport = 'http' },
                [pscustomobject]@{ name = 'pdbsql'; transport = 'sse' }) } }
    }

    It 'rejects unwaived Claude residue in quoted history' {
        '> TodoWrite' | Set-Content (Join-Path $source 'reference.md')
        { New-CodexSkillCandidate @params } | Should -Throw '*C4-TODOWRITE*reference.md*'
        Test-Path (Split-Path $script:params.Destination) | Should -BeFalse
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

Describe 'Codex custom-agent generation' {
    BeforeEach {
        $script:CodexAgentRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:CodexAgentTemplates = Join-Path $script:CodexAgentRoot 'templates'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:CodexAgentTemplates 'agents') -Force
        $instructionDir = Join-Path $script:CodexAgentTemplates 'instructions'
        $null = New-Item -ItemType Directory -Path $instructionDir -Force
        '# fixture contract' | Set-Content (Join-Path $instructionDir 'common.md.template')
        '# fixture Codex' | Set-Content (Join-Path $instructionDir 'codex.md.template')
        @(
            @{ Name = 'static-analyst'; Description = 'Static "analysis"'; Body = 'Static body with """ safely embedded.{{CLIENT_LIMITATIONS}}' }
            @{ Name = 'verifier'; Description = 'Independent verifier'; Body = 'Verifier body.{{CLIENT_LIMITATIONS}}' }
            @{ Name = 'dynamic-analyst'; Description = 'Disabled dynamic role'; Body = 'Dynamic body.{{CLIENT_LIMITATIONS}}' }
        ) | ForEach-Object {
            "---`nname: $($_.Name)`ndescription: $($_.Description)`ntools: ignored`n---`n$($_.Body)" |
                Set-Content (Join-Path $script:CodexAgentTemplates "agents\$($_.Name).md.template")
        }
        $script:CodexAgentConfig = [pscustomobject]@{
            paths = [pscustomobject]@{ agentRoot = $script:CodexAgentRoot }
            mcpServers = @(
                [pscustomobject]@{ name = 'x64dbg-x64'; transport = 'http'; auth = 'bearer-generated' }
                [pscustomobject]@{ name = 'x64dbg-x32'; transport = 'http'; auth = 'bearer-generated' }
                [pscustomobject]@{ name = 'binaryninja'; transport = 'http'; auth = 'bearer-generated' }
                [pscustomobject]@{ name = 'pyghidra-mcp'; transport = 'http'; auth = 'none' }
                [pscustomobject]@{ name = 'mcp-windbg'; transport = 'stdio'; auth = 'none' }
                [pscustomobject]@{ name = 'pdbsql'; transport = 'sse'; auth = 'none' }
                [pscustomobject]@{ name = 'ghidrasql'; transport = 'sse'; auth = 'none' }
                [pscustomobject]@{ name = 'ghidramcp'; transport = 'sse'; auth = 'bearer-generated' }
            )
            agents = @(
                [pscustomobject]@{ name = 'static-analyst'; enabled = $true; level = 'write'
                    targetServers = @('pyghidra-mcp', 'pdbsql', 'ghidrasql'); builtinTools = @('Read') }
                [pscustomobject]@{ name = 'verifier'; enabled = $true; level = 'read'
                    targetServers = @('pyghidra-mcp', 'mcp-windbg', 'pdbsql'); builtinTools = @('Read') }
                [pscustomobject]@{ name = 'dynamic-analyst'; enabled = $false; level = 'write'
                    targetServers = @('mcp-windbg'); builtinTools = @('Read'); disabledReason = 'deferred' }
            )
        }
        $script:CodexAgentCatalog = [pscustomobject]@{ servers = [pscustomobject]@{
                'pyghidra-mcp' = [pscustomobject]@{ tools = @('read_binary', 'rename_function', 'delete_binary'); classification = [pscustomobject]@{
                        classifiedTools = @('read_binary', 'rename_function', 'delete_binary'); write = @('rename_function'); destructive = @('delete_binary') } }
                'mcp-windbg' = [pscustomobject]@{ tools = @('list_dumps', 'write_memory'); classification = [pscustomobject]@{
                        classifiedTools = @('list_dumps', 'write_memory'); write = @('write_memory'); destructive = @() } }
            } }
        $command = [pscustomobject]@{ Executable = 'C:\\tools\\windbg.exe'; Arguments = @('--mcp'); Env = @{} }
        $script:CodexAgentResults = @(
            [pscustomobject]@{ Name = 'x64dbg-x64'; Installed = $true; Transport = 'http'; Bind = '127.0.0.1'; Port = 9100; Path = '/mcp'; Auth = 'bearer-generated' }
            [pscustomobject]@{ Name = 'x64dbg-x32'; Installed = $true; Transport = 'http'; Bind = '127.0.0.1'; Port = 9101; Path = '/mcp'; Auth = 'bearer-generated' }
            [pscustomobject]@{ Name = 'binaryninja'; Installed = $true; Transport = 'http'; Bind = '127.0.0.1'; Port = 9102; Path = '/mcp'; Auth = 'bearer-generated' }
            [pscustomobject]@{ Name = 'pyghidra-mcp'; Installed = $true; Transport = 'http'; Bind = '127.0.0.1'; Port = 9103; Path = '/mcp'; Auth = 'none' }
            [pscustomobject]@{ Name = 'mcp-windbg'; Installed = $true; Transport = 'stdio'; Command = $command; Auth = 'none' }
            [pscustomobject]@{ Name = 'pdbsql'; Installed = $true; Transport = 'sse'; Auth = 'none' }
            [pscustomobject]@{ Name = 'ghidrasql'; Installed = $true; Transport = 'sse'; Auth = 'none' }
            [pscustomobject]@{ Name = 'ghidramcp'; Installed = $true; Transport = 'sse'; Auth = 'bearer-generated' }
        )
    }

    It 'renders complete token-free specialist TOML with exact grants and omissions' {
        $result = Write-CodexAgentDefinition -Config $script:CodexAgentConfig -Catalog $script:CodexAgentCatalog `
            -ServerResults $script:CodexAgentResults -TemplateRoot $script:CodexAgentTemplates
        $static = Get-Content -LiteralPath (Join-Path $script:CodexAgentRoot '.codex\agents\static-analyst.toml') -Raw
        $verifier = Get-Content -LiteralPath (Join-Path $script:CodexAgentRoot '.codex\agents\verifier.toml') -Raw

        foreach ($text in @($static, $verifier)) {
            $text | Should -Match '^# re-agent-managed: codex-custom-agent v1'
            foreach ($field in @('name', 'description', 'developer_instructions', 'sandbox_mode')) {
                $text | Should -Match ('(?m)^' + $field + ' = "')
            }
            @([regex]::Matches($text, '(?m)^\[mcp_servers\."[^"]+"\]$')).Count | Should -Be 5
            $text | Should -Not -Match '(?i)bearer|authorization|fixture-sensitive-token'
            $text | Should -Not -Match '(?m)^\[mcp_servers\."(?:pdbsql|ghidrasql|ghidramcp)"\]$'
        }
        $static | Should -Match '(?m)^sandbox_mode = "workspace-write"$'
        $verifier | Should -Match '(?m)^sandbox_mode = "read-only"$'
        $static | Should -Match 'mcp_servers\."pyghidra-mcp"\][\s\S]*enabled_tools = \["read_binary","rename_function"\]'
        $static | Should -Not -Match 'delete_binary'
        $verifier | Should -Match 'mcp_servers\."pyghidra-mcp"\][\s\S]*enabled_tools = \["read_binary"\]'
        $verifier | Should -Match 'mcp_servers\."mcp-windbg"\][\s\S]*enabled_tools = \["list_dumps"\]'
        @($result.OmittedServers | Where-Object { $_.Reason -eq 'legacy SSE is unsupported by Codex' }).Count |
            Should -Be 3
        Test-Path (Join-Path $script:CodexAgentRoot '.codex\agents\dynamic-analyst.toml') | Should -BeFalse
    }

    It 'removes only a marked disabled agent and refuses an unmarked name collision' {
        $dir = Join-Path $script:CodexAgentRoot '.codex\agents'
        $null = New-Item -ItemType Directory -Path $dir -Force
        '# re-agent-managed: codex-custom-agent v1' | Set-Content (Join-Path $dir 'dynamic-analyst.toml')
        'operator owned' | Set-Content (Join-Path $dir 'static-analyst.toml')

        { Write-CodexAgentDefinition -Config $script:CodexAgentConfig -Catalog $script:CodexAgentCatalog `
                -ServerResults $script:CodexAgentResults -TemplateRoot $script:CodexAgentTemplates } |
            Should -Throw '*unmanaged*'

        Test-Path (Join-Path $dir 'dynamic-analyst.toml') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $dir 'static-analyst.toml') -Raw | Should -Match '^operator owned'
    }

    It 'refuses an authenticated compatible target before writing any agent file' {
        $script:CodexAgentConfig.agents[0].targetServers += 'x64dbg-x64'

        { Write-CodexAgentDefinition -Config $script:CodexAgentConfig -Catalog $script:CodexAgentCatalog `
                -ServerResults $script:CodexAgentResults -TemplateRoot $script:CodexAgentTemplates } |
            Should -Throw '*Authenticated*cannot be enabled*'

        Test-Path (Join-Path $script:CodexAgentRoot '.codex\agents\static-analyst.toml') | Should -BeFalse
    }

    It 'composes omission records when the configuration includes a disabled agent' {
        $workspace = Write-CodexWorkspaceConfiguration -Config $script:CodexAgentConfig `
            -Catalog $script:CodexAgentCatalog -ServerResults $script:CodexAgentResults `
            -TemplateRoot $script:CodexAgentTemplates

        $workspace.Agents.Count | Should -Be 3
        @($workspace.OmittedServers).Count | Should -Be 3
        @(@($workspace.Agents | Where-Object { -not $_.Enabled })[0].OmittedServers).Count |
            Should -Be 0
    }

    It 'enables a compatible target even when its derived catalog grant is empty' {
        $script:CodexAgentConfig.mcpServers += [pscustomobject]@{
            name = 'catalog-empty'; transport = 'http'; auth = 'none'
        }
        $script:CodexAgentConfig.agents[0].targetServers += 'catalog-empty'
        $script:CodexAgentResults += [pscustomobject]@{
            Name = 'catalog-empty'; Installed = $true; Transport = 'http'
            Bind = '127.0.0.1'; Port = 9104; Path = '/mcp'; Auth = 'none'
        }

        $toml = New-CodexAgentToml -Agent $script:CodexAgentConfig.agents[0] `
            -Catalog $script:CodexAgentCatalog -Config $script:CodexAgentConfig `
            -ServerResults $script:CodexAgentResults -TemplateRoot $script:CodexAgentTemplates

        $toml | Should -Match (
            '(?m)^\[mcp_servers\."catalog-empty"\]\r?$\r?\n' +
            'enabled = true\r?\nenabled_tools = \[\]')
    }
}
