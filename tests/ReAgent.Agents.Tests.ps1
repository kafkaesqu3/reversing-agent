BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Skills.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Agents.psm1" -Force

    function Get-TestCatalog {
        param([string[]]$Tools = @('decompile_function', 'rename_function', 'delete_project_binary'),
              [string[]]$Classified = $null,
              [string[]]$Write = @('rename_function'),
              [string[]]$Destructive = @('delete_project_binary'))
        if ($null -eq $Classified) { $Classified = $Tools }
        [PSCustomObject]@{ servers = [PSCustomObject]@{
                'pyghidra-mcp' = [PSCustomObject]@{
                    pin = '0.2.5'; toolCount = $Tools.Count; tools = $Tools
                    classification = [PSCustomObject]@{
                        classifiedBy = 'test'; classifiedAt = '2026-09-08'
                        classifiedTools = $Classified; write = $Write
                        destructive = $Destructive } } } }
    }
}

Describe 'Get-ToolClassification' {
    It 'reports a server with no classification as unknown rather than empty' {
        $cat = [PSCustomObject]@{ servers = [PSCustomObject]@{
                'binaryninja' = [PSCustomObject]@{ pin = '1.0'; tools = @('bn_list') } } }
        (Get-ToolClassification -Catalog $cat -Server 'binaryninja').Known | Should -BeFalse
    }

    It 'reads the three lists off a classified server' {
        $c = Get-ToolClassification -Catalog (Get-TestCatalog) -Server 'pyghidra-mcp'
        $c.Known | Should -BeTrue
        $c.Write | Should -Contain 'rename_function'
        $c.Destructive | Should -Contain 'delete_project_binary'
    }
}

Describe 'Get-ToolLevel' {
    It 'defaults a classified tool in neither list to read' {
        $c = Get-ToolClassification -Catalog (Get-TestCatalog) -Server 'pyghidra-mcp'
        Get-ToolLevel -Classification $c -Tool 'decompile_function' | Should -Be 'read'
    }

    It 'takes the highest list a tool appears in' {
        $cat = Get-TestCatalog -Write @('save') -Destructive @('save')
        $c = Get-ToolClassification -Catalog $cat -Server 'pyghidra-mcp'
        Get-ToolLevel -Classification $c -Tool 'save' | Should -Be 'destructive'
    }
}

Describe 'Test-AgentClassificationCheck (A4)' {
    It 'passes when classifiedTools equals tools as a set, ignoring order' {
        $cat = Get-TestCatalog -Classified @('delete_project_binary', 'decompile_function',
            'rename_function')
        Test-AgentClassificationCheck -Catalog $cat -Server 'pyghidra-mcp' | Should -BeNullOrEmpty
    }

    It 'fails A4 when a catalog refresh adds a tool nobody classified' {
        # NEGATIVE TEST 3 from spec 11: this is the failure that would otherwise hand an
        # unclassified tool to the verifier as if it were readable.
        $cat = Get-TestCatalog -Tools @('decompile_function', 'rename_function',
            'delete_project_binary', 'brand_new_tool') -Classified @('decompile_function',
            'rename_function', 'delete_project_binary')
        $f = Test-AgentClassificationCheck -Catalog $cat -Server 'pyghidra-mcp'
        @($f).Count | Should -Be 1
        $f[0].Check | Should -Be 'A4'
        $f[0].Message | Should -BeLike '*brand_new_tool*'
    }

    It 'fails A4 when a classification names a tool the server no longer advertises' {
        $cat = Get-TestCatalog -Classified @('decompile_function', 'rename_function',
            'delete_project_binary', 'removed_upstream')
        $f = Test-AgentClassificationCheck -Catalog $cat -Server 'pyghidra-mcp'
        $f[0].Message | Should -BeLike '*removed_upstream*'
    }
}

Describe 'the checked-in catalog' {
    It 'classifies every tool of every captured server' {
        $cat = Get-ToolCatalog
        foreach ($name in $cat.servers.PSObject.Properties.Name) {
            Test-AgentClassificationCheck -Catalog $cat -Server $name |
                Should -BeNullOrEmpty -Because "server '$name' must be fully classified"
        }
    }

    It 'grants delete_project_binary to nobody by classifying it destructive' {
        $c = Get-ToolClassification -Catalog (Get-ToolCatalog) -Server 'pyghidra-mcp'
        $c.Destructive | Should -Contain 'delete_project_binary'
    }
}

Describe 'Get-AgentToolGrant' {
    BeforeAll {
        function Get-GrantAgent {
            param($Level = 'read', $Servers = @('pyghidra-mcp'), $Builtins = @('Read', 'Glob', 'Grep'))
            [PSCustomObject]@{ name = 'verifier'; enabled = $true; level = $Level
                targetServers = $Servers; builtinTools = $Builtins }
        }
    }

    It 'grants a read agent only the read tools' {
        $g = Get-AgentToolGrant -Agent (Get-GrantAgent) -Catalog (Get-TestCatalog)
        $g.Tools | Should -Contain 'mcp__pyghidra-mcp__decompile_function'
        $g.Tools | Should -Not -Contain 'mcp__pyghidra-mcp__rename_function'
    }

    It 'grants a write agent read plus write, never destructive' {
        $g = Get-AgentToolGrant -Agent (Get-GrantAgent -Level 'write') -Catalog (Get-TestCatalog)
        $g.Tools | Should -Contain 'mcp__pyghidra-mcp__rename_function'
        $g.Tools | Should -Contain 'mcp__pyghidra-mcp__decompile_function'
        $g.Tools | Should -Not -Contain 'mcp__pyghidra-mcp__delete_project_binary'
    }

    It 'puts built-ins first in declared order, then MCP tools sorted by name' {
        # Byte-identical regeneration depends on this being total, not incidental.
        $g = Get-AgentToolGrant -Agent (Get-GrantAgent) -Catalog (Get-TestCatalog)
        $g.Tools[0] | Should -Be 'Read'
        $g.Tools[1] | Should -Be 'Glob'
        $g.Tools[2] | Should -Be 'Grep'
        $mcp = @($g.Tools | Select-Object -Skip 3)
        ($mcp -join ',') | Should -Be (($mcp | Sort-Object) -join ',')
    }

    It 'contributes nothing for a server with no classification' {
        $cat = [PSCustomObject]@{ servers = [PSCustomObject]@{
                'binaryninja' = [PSCustomObject]@{ tools = @('bn_list') } } }
        $g = Get-AgentToolGrant -Agent (Get-GrantAgent -Servers @('binaryninja')) -Catalog $cat
        $g.McpCount | Should -Be 0
        $g.Tools.Count | Should -Be 3
    }
}

Describe 'Test-AgentNameCheck (A0)' {
    It 'passes when frontmatter, filename and config name all agree' {
        Test-AgentNameCheck -Frontmatter @{ name = 'verifier' } -FileBaseName 'verifier' `
            -ConfigName 'verifier' | Should -BeNullOrEmpty
    }

    It 'fails A0 when frontmatter disagrees with the filename' {
        # NEGATIVE TEST 4 from spec 11. Claude Code will not load the file at all.
        $f = Test-AgentNameCheck -Frontmatter @{ name = 'verify' } -FileBaseName 'verifier' `
            -ConfigName 'verifier'
        @($f).Count | Should -Be 1
        $f[0].Check | Should -Be 'A0'
    }
}

Describe 'Test-AgentCatalogCheck (A1)' {
    It 'fails A1 for a target server the catalog has never measured' {
        $a = [PSCustomObject]@{ name = 'dynamic-analyst'; level = 'write'
            targetServers = @('x64dbg-x64'); builtinTools = @('Read') }
        $f = Test-AgentCatalogCheck -Agent $a -Catalog (Get-TestCatalog)
        $f[0].Check | Should -Be 'A1'
        $f[0].Message | Should -BeLike '*x64dbg-x64*'
    }
}

Describe 'Test-AgentToolExistenceCheck (A2)' {
    It 'fails A2 for a granted tool absent from the catalog' {
        # NEGATIVE TEST 1 from spec 11.
        $f = Test-AgentToolExistenceCheck `
            -GrantedTools @('Read', 'mcp__pyghidra-mcp__invented_tool') `
            -Catalog (Get-TestCatalog)
        $f[0].Check | Should -Be 'A2'
        $f[0].Message | Should -BeLike '*invented_tool*'
    }

    It 'ignores built-ins, which are not catalog tools' {
        Test-AgentToolExistenceCheck -GrantedTools @('Read', 'Glob') `
            -Catalog (Get-TestCatalog) | Should -BeNullOrEmpty
    }

    It 'fails A2 for a granted tool with a server absent from the catalog' {
        $f = Test-AgentToolExistenceCheck -GrantedTools @('mcp__totally-fake-server__anything') `
            -Catalog (Get-TestCatalog)
        $f[0].Check | Should -Be 'A2'
        $f[0].Message | Should -BeLike '*totally-fake-server*'
    }
}

Describe 'Test-AgentLevelCheck (A3)' {
    It 'fails A3 when the verifier is granted a write tool' {
        # NEGATIVE TEST 2 from spec 11, and the check that carries
        # DEPLOYMENT_PLAN Phase 7: "If the verifier can write, it isn't a verifier."
        $a = [PSCustomObject]@{ name = 'verifier'; level = 'read'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read') }
        $f = Test-AgentLevelCheck -Agent $a `
            -GrantedTools @('Read', 'mcp__pyghidra-mcp__rename_function') `
            -Catalog (Get-TestCatalog)
        $f[0].Check | Should -Be 'A3'
        $f[0].Message | Should -BeLike '*rename_function*'
    }

    It 'fails A3 when any agent is granted a destructive tool' {
        $a = [PSCustomObject]@{ name = 'static-analyst'; level = 'write'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read') }
        $f = Test-AgentLevelCheck -Agent $a `
            -GrantedTools @('mcp__pyghidra-mcp__delete_project_binary') `
            -Catalog (Get-TestCatalog)
        $f[0].Check | Should -Be 'A3'
    }

    It 'fails A3 on a forbidden built-in that slipped past config validation' {
        $a = [PSCustomObject]@{ name = 'verifier'; level = 'read'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Bash') }
        $f = Test-AgentLevelCheck -Agent $a -GrantedTools @('Read', 'Bash') `
            -Catalog (Get-TestCatalog)
        $f[0].Message | Should -BeLike '*Bash*'
    }

    It 'passes a correctly derived verifier grant' {
        $a = [PSCustomObject]@{ name = 'verifier'; level = 'read'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Glob', 'Grep') }
        $g = Get-AgentToolGrant -Agent $a -Catalog (Get-TestCatalog)
        Test-AgentLevelCheck -Agent $a -GrantedTools $g.Tools -Catalog (Get-TestCatalog) |
            Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AgentGate' {
    It 'returns findings from every check at once, not just the first' {
        $a = [PSCustomObject]@{ name = 'verifier'; level = 'read'
            targetServers = @('pyghidra-mcp', 'x64dbg-x64'); builtinTools = @('Read') }
        $f = Invoke-AgentGate -Agent $a -Catalog (Get-TestCatalog) `
            -Frontmatter @{ name = 'wrong' } -FileBaseName 'verifier'
        @($f | Where-Object { $_.Check -eq 'A0' }).Count | Should -Be 1
        @($f | Where-Object { $_.Check -eq 'A1' }).Count | Should -Be 1
    }
}

Describe 'agent templates' {
    BeforeAll { $script:TplDir = Join-Path $PSScriptRoot '../templates/agents' }

    It 'ships one template per agent the spec names' {
        foreach ($n in @('static-analyst', 'dynamic-analyst', 'verifier')) {
            Test-Path (Join-Path $script:TplDir "$n.md.template") | Should -BeTrue
        }
    }

    It 'carries all three substitution tokens in every template' {
        foreach ($f in Get-ChildItem $script:TplDir -Filter '*.md.template') {
            $t = Get-Content -LiteralPath $f.FullName -Raw
            $t | Should -BeLike '*{{TOOLS}}*'
            $t | Should -BeLike '*{{SERVERS}}*'
            $t | Should -BeLike '*{{LIMITATIONS}}*'
        }
    }

    It 'opens the verifier with the ai_ exclusion rule, before its tool list' {
        # Spec 4.1: without this, adding a verifier makes output look better-verified
        # while verifying nothing - worse than having no verifier at all.
        $t = Get-Content -LiteralPath (Join-Path $script:TplDir 'verifier.md.template') -Raw
        $t | Should -BeLike '*ai_*'
        $t.IndexOf('ai_') | Should -BeLessThan $t.IndexOf('## Servers you reach')
    }

    It 'tells the dynamic analyst that TTD replay is unavailable' {
        # Spec 4.2: the agent should report the limitation, not discover it mid-case.
        $t = Get-Content -LiteralPath (Join-Path $script:TplDir 'dynamic-analyst.md.template') -Raw
        $t | Should -BeLike '*0x80070057*'
    }

    It 'tells the static analyst it has no Bash, so msvc_demangle cannot run' {
        $t = Get-Content -LiteralPath (Join-Path $script:TplDir 'static-analyst.md.template') -Raw
        $t | Should -BeLike '*msvc_demangle*'
    }

    It 'stamps every agent name into its own findings contract' {
        foreach ($f in Get-ChildItem $script:TplDir -Filter '*.md.template') {
            (Get-Content -LiteralPath $f.FullName -Raw) | Should -BeLike '*finding*'
        }
    }
}

