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
