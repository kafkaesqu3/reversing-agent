# Agent Topology Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate three specialist subagent definitions into `C:\re\agent\.claude\agents\`, each
with a tool grant derived from `data/tool-catalog.json`, gated so a writer can never reach the
verifier.

**Architecture:** A new `classification` block per server in the tool catalog names each captured
tool `read` / `write` / `destructive`. A new `agents[]` block in `re-agent.config.json` declares
each agent's maximum level and target servers. A new module `src/ReAgent.Agents.psm1` turns those
two data sources into a concrete tool list, and runs five `A`-prefixed gate checks over the result.
Generation folds into existing phase 4 (`AgentConfig`); the gate runs in phase 6 (`Verify`).

**Tech Stack:** PowerShell 5.1-compatible modules under `src/`, Pester 5.5.0+ under `tests/`,
token-substituted templates under `templates/` (no templating engine — DEPLOYMENT_PLAN Part 4).

**Spec:** `docs/superpowers/specs/2026-09-07-agent-topology-design.md`

## Global Constraints

- **Branch:** `feat/agent-topology`, based on `feat/skills-vendoring` (spec AG7). That base is
  under active development by another session — rebase before starting and expect to rebase again.
- **Never run the real installer.** Ledger rule R3. Phase functions are exercised through tests
  with the host mocked, never by invoking `.\Install-REAgent.ps1` against `C:\re\agent`.
- **The catalog is the authority** for whether a tool exists. Never hand-list a tool name that is
  not in `data/tool-catalog.json`. Ledger warns this bit Task 16 via bad catalog data.
- **`Z:` is an SMB share: `Edit`/`Write` fail with `ENOENT fchmod` when overwriting an existing
  file.** Create new files with `Write`; patch existing files with a Python script.
- **Line endings:** `.gitattributes` pins `* text=auto eol=lf`. Checks that anchor on `^## Heading$`
  are line-ending sensitive — do not reintroduce a CRLF dependency.
- Hard limits: ≤100 lines/function, cyclomatic complexity ≤8, ≤5 positional params, 100-char lines,
  comment-based help on every exported function.
- Zero warnings from PSScriptAnalyzer. Fix or inline-suppress with justification.
- New gate checks are `A`-prefixed (`A0`–`A4`) so they never read as skills' `G0`–`G4`.
- Every generated file is written through `Write-FileIfChanged` so a steady-state run touches no
  timestamp.
- Commit after each task. Imperative mood, ≤72-char subject, no AI attribution lines.

---

## Open questions — resolve before Task 1 is committed

**OQ1 — What level are `run_cdb_command` and `run_kd_command`?** This decides whether the verifier
can use `mcp-windbg` at all, and the spec does not settle it.

The two commands are the debugger's entire surface: `dd` reads memory, `ed` writes it, `.attach`
takes a live process. They cannot be sub-classified without parsing the command string, which is a
denylist and will be bypassed.

- If they are `write`, then A3 strips them from the verifier, and the verifier's `mcp-windbg` grant
  reduces to `list_dumps`, `open_cdb_dump` and `wait_for_break` — it can open a dump and read
  nothing out of it. Spec §4's table grants the verifier `mcp-windbg`, but that grant would be
  inert, and shipping an inert grant is the phantom-feature failure AGENTS.md forbids.
- If they are `read`, the verifier can inspect dumps, but a single unconstrained tool defeats A3 —
  the verifier could `ed` memory in a live session. That is exactly "if the verifier can write, it
  isn't a verifier."

**Recommendation: classify both `write`, and drop `mcp-windbg` from the verifier's `targetServers`,
recording it in spec §12 as a gap** — the verifier verifies static analysis only until a read-only
dump-query tool exists. This keeps A3 meaningful and refuses to ship an inert grant. Task 1 and
Task 9 both assume this; if the ruling differs, change the classification in Task 1 Step 1 and the
config in Task 9 Step 1 and nothing else moves.

**OQ2 — `re-agent.config.json` declares six MCP servers, not the five spec §4 assumes.** They are
`x64dbg-x64`, `x64dbg-x32`, `binaryninja`, `pyghidra-mcp`, `mcp-windbg`, `ghidramcp`. `ghidramcp`
appears in no agent's `targetServers` in spec §4 and has no catalog entry. No action needed — A1
fails closed on any server without a catalog entry, and no agent names it — but the spec's
"five-server tool surface" phrasing in AG1 is off by one and should be corrected when convenient.

---

## File Structure

| File | Responsibility |
|---|---|
| `data/tool-catalog.json` | **Modify.** Gains `classification` beside `tools[]` for each captured server. |
| `src/ReAgent.Agents.psm1` | **Create.** Classification reader, grant computation, checks A0–A4, `New-AgentResult`. |
| `src/ReAgent.Config.psm1` | **Modify.** `Test-AgentSchema` validates the optional `agents[]` block. |
| `templates/agents/*.md.template` | **Create.** Three agent bodies with `{{TOOLS}}`, `{{SERVERS}}`, `{{LIMITATIONS}}`. |
| `src/ReAgent.Generate.psm1` | **Modify.** `Write-AgentDefinition`, called from `Write-AgentConfiguration`. |
| `templates/CLAUDE.md.template` | **Modify.** Gains the `## Agents` routing section. |
| `src/ReAgent.Manifest.psm1` | **Modify.** `agents[]` manifest block and `Get-RecordedAgentResult`. |
| `src/ReAgent.Verify.psm1` | **Modify.** Runs the agent gate inside phase 6. |
| `re-agent.config.json` | **Modify.** Declares the three agents. |
| `tests/ReAgent.Agents.Tests.ps1` | **Create.** Unit tests for the module, including the five negative tests. |

---

### Task 1: Classify the captured tool surface

The gate cannot judge a grant until every captured tool has a level. This task adds the data and
the check that keeps it honest when the catalog is refreshed.

**Files:**
- Modify: `data/tool-catalog.json`
- Create: `src/ReAgent.Agents.psm1`
- Create: `tests/ReAgent.Agents.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ToolCatalog` from `src/ReAgent.Skills.psm1` (already exported).
- Produces:
  - `Get-ToolClassification -Catalog <object> -Server <string>` →
    `[PSCustomObject]@{ Known=[bool]; ClassifiedTools=[string[]]; Write=[string[]]; Destructive=[string[]] }`
  - `Get-ToolLevel -Classification <object> -Tool <string>` → `'read'|'write'|'destructive'`
  - `Test-AgentClassificationCheck -Catalog <object> -Server <string>` → `[array]` of
    `{Check='A4'; Message}`

- [ ] **Step 1: Add the classification block to the catalog**

`data/tool-catalog.json` is an existing file on the `Z:` share — patch it with a Python script, not
`Edit`. Write `tools/patch-catalog.py` (delete it after the commit):

```python
import json, collections
p = 'data/tool-catalog.json'
d = json.load(open(p, encoding='utf-8'), object_pairs_hook=collections.OrderedDict)

d['servers']['pyghidra-mcp']['classification'] = collections.OrderedDict([
    ('classifiedBy', 'david'),
    ('classifiedAt', '2026-09-08'),
    ('classifiedTools', sorted(d['servers']['pyghidra-mcp']['tools'])),
    ('write', ['import_binary', 'rename_function', 'rename_variable', 'save',
               'set_comment', 'set_function_prototype', 'set_variable_type']),
    ('destructive', ['delete_project_binary']),
])
d['servers']['mcp-windbg']['classification'] = collections.OrderedDict([
    ('classifiedBy', 'david'),
    ('classifiedAt', '2026-09-08'),
    ('classifiedTools', sorted(d['servers']['mcp-windbg']['tools'])),
    ('write', ['close_cdb_session', 'close_kd_session', 'open_cdb_dump',
               'open_cdb_remote', 'open_kd_session', 'run_cdb_command',
               'run_kd_command', 'send_ctrl_break']),
    ('destructive', []),
])
open(p, 'w', encoding='utf-8', newline='\n').write(json.dumps(d, indent=2) + '\n')
print('patched')
```

Run: `python tools/patch-catalog.py`

Rationale to record in the commit message: `import_binary` mutates the project, so it is `write`
even though the spec's illustrative example omitted it. `run_cdb_command` and `run_kd_command` are
`write` per **OQ1** — they are unconstrained debugger surfaces and cannot be sub-classified without
a denylist. `wait_for_break` and `list_dumps` are the only `mcp-windbg` reads.

- [ ] **Step 2: Write the failing tests**

Create `tests/ReAgent.Agents.Tests.ps1`:

```powershell
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
            'delete_project_binary', 'brand_new_tool')
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `The specified module '.../src/ReAgent.Agents.psm1' was not loaded`.

- [ ] **Step 4: Create the module**

Create `src/ReAgent.Agents.psm1`:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ToolClassification {
    <#
    .SYNOPSIS
        Reads one server's tool classification out of the catalog.
    .DESCRIPTION
        The classification is a sibling of the captured tools[], never inside
        it (spec AG4): -UpdateToolCatalog rewrites tools[] and must not be able
        to erase a classification, nor be blocked by one.

        A server with no classification returns Known=$false rather than empty
        lists. Empty lists would read as "everything here is readable", which
        is the failure that hands an unjudged tool to the verifier.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        MCP server name.
    .OUTPUTS
        [PSCustomObject] Known, ClassifiedTools, Write, Destructive.
    .EXAMPLE
        Get-ToolClassification -Catalog (Get-ToolCatalog) -Server 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server
    )

    $absent = [PSCustomObject]@{ Known = $false; ClassifiedTools = @()
        Write = @(); Destructive = @() }
    if ($Catalog.servers.PSObject.Properties.Name -notcontains $Server) { return $absent }
    $entry = $Catalog.servers.$Server
    if ($entry.PSObject.Properties.Name -notcontains 'classification') { return $absent }

    $c = $entry.classification
    return [PSCustomObject]@{
        Known           = $true
        ClassifiedTools = @($c.classifiedTools)
        Write           = @($c.write)
        Destructive     = @($c.destructive)
    }
}

function Get-ToolLevel {
    <#
    .SYNOPSIS
        Returns a single tool's level: read, write or destructive.
    .DESCRIPTION
        Anything classified and in neither list is read. A tool listed twice
        takes the highest level, so a careless duplicate fails safe upward
        rather than downward.
    .PARAMETER Classification
        From Get-ToolClassification.
    .PARAMETER Tool
        Bare tool name, without the mcp__server__ prefix.
    .OUTPUTS
        [string] read | write | destructive.
    .EXAMPLE
        Get-ToolLevel -Classification $c -Tool 'save'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Classification,
        [Parameter(Mandatory)][string]$Tool
    )

    if ($Classification.Destructive -contains $Tool) { return 'destructive' }
    if ($Classification.Write -contains $Tool) { return 'write' }
    return 'read'
}

function Test-AgentClassificationCheck {
    <#
    .SYNOPSIS
        Runs check A4: a server's classification must cover its tools exactly.
    .DESCRIPTION
        Set equality in both directions. A tool captured but unclassified would
        default to read and reach the verifier; a tool classified but no longer
        captured means the classification is describing a surface that moved.
        Both are stale data, and the gate stops rather than guessing.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        MCP server name.
    .OUTPUTS
        [array] Zero or one {Check='A4'; Message} findings.
    .EXAMPLE
        Test-AgentClassificationCheck -Catalog $cat -Server 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server
    )

    $class = Get-ToolClassification -Catalog $Catalog -Server $Server
    if (-not $class.Known) { return @() }

    $captured = @($Catalog.servers.$Server.tools)
    $unclassified = @($captured | Where-Object { $class.ClassifiedTools -notcontains $_ })
    $stale = @($class.ClassifiedTools | Where-Object { $captured -notcontains $_ })
    if ($unclassified.Count -eq 0 -and $stale.Count -eq 0) { return @() }

    $parts = @()
    if ($unclassified.Count) { $parts += "captured but unclassified: [$($unclassified -join ', ')]" }
    if ($stale.Count) { $parts += "classified but not captured: [$($stale -join ', ')]" }
    return @([PSCustomObject]@{ Check = 'A4'; Message = (
                "Server '$Server' classification is stale - $($parts -join '; '). " +
                'Reclassify before any agent may be granted this server.') })
}

Export-ModuleMember -Function Get-ToolClassification, Get-ToolLevel, `
    Test-AgentClassificationCheck
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: PASS, 9 tests.

- [ ] **Step 6: Delete the patch script and run the analyzer**

Run:
```bash
powershell.exe -NoProfile -Command "Remove-Item tools/patch-catalog.py; Invoke-ScriptAnalyzer -Path src/ReAgent.Agents.psm1 -Severity Warning,Error"
```
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add data/tool-catalog.json src/ReAgent.Agents.psm1 tests/ReAgent.Agents.Tests.ps1
git commit -m "Classify every captured tool so a grant can be judged"
```

---

### Task 2: Validate the agents block at config load

**Files:**
- Modify: `src/ReAgent.Config.psm1` (add `Test-AgentSchema`, extend `Test-ReAgentConfigSchema`, extend `Export-ModuleMember` at line 278)
- Test: `tests/ReAgent.Config.Tests.ps1`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Test-AgentSchema -Config <object>` → throws on an invalid `agents[]`, returns silently
  otherwise. Absent `agents` key is valid.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Config.Tests.ps1`:

```powershell
Describe 'Test-AgentSchema' {
    function Get-TestAgentConfig {
        param($Agents)
        [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' },
                [PSCustomObject]@{ name = 'mcp-windbg' })
            agents     = $Agents
        }
    }
    function Get-TestAgent {
        param($Name = 'verifier', $Level = 'read', $Servers = @('pyghidra-mcp'),
              $Builtins = @('Read', 'Glob', 'Grep'), $Enabled = $true, $Reason = '')
        [PSCustomObject]@{ name = $Name; enabled = $Enabled; level = $Level
            targetServers = $Servers; builtinTools = $Builtins
            model = 'inherit'; disabledReason = $Reason }
    }

    It 'accepts a config with no agents key at all' {
        # StrictMode defect the skills slice already hit in Get-RecordedSkillResult.
        { Test-AgentSchema -Config ([PSCustomObject]@{ mcpServers = @() }) } | Should -Not -Throw
    }

    It 'accepts a well-formed agent' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent)) } | Should -Not -Throw
    }

    It 'rejects a name that is not a valid file basename' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent -Name 'Verifier')) } |
            Should -Throw '*Verifier*'
    }

    It 'rejects two agents sharing a name' {
        $c = Get-TestAgentConfig @((Get-TestAgent), (Get-TestAgent))
        { Test-AgentSchema -Config $c } | Should -Throw '*duplicate*'
    }

    It 'rejects an agent declaring level destructive' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent -Level 'destructive')) } |
            Should -Throw '*destructive*'
    }

    It 'rejects a targetServer absent from mcpServers' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Servers @('ida-pro'))
        { Test-AgentSchema -Config $c } | Should -Throw '*ida-pro*'
    }

    It 'rejects Bash in builtinTools' {
        # NEGATIVE TEST 5 from spec 11. BLUEPRINT 7.1: no host code execution while
        # the model is reading untrusted decompiler output.
        $c = Get-TestAgentConfig @(Get-TestAgent -Builtins @('Read', 'Bash'))
        { Test-AgentSchema -Config $c } | Should -Throw '*Bash*'
    }

    It 'rejects Task in builtinTools so no agent can spawn an agent' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Builtins @('Read', 'Task'))
        { Test-AgentSchema -Config $c } | Should -Throw '*Task*'
    }

    It 'requires a reason when an agent ships disabled' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Enabled $false -Reason '')
        { Test-AgentSchema -Config $c } | Should -Throw '*disabledReason*'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Test-AgentSchema` is not recognized.

- [ ] **Step 3: Implement `Test-AgentSchema`**

Add to `src/ReAgent.Config.psm1`, above `Export-ModuleMember`:

```powershell
$script:ForbiddenBuiltinTool = @('Bash', 'Write', 'Edit', 'NotebookEdit', 'Task')

function Test-AgentSchema {
    <#
    .SYNOPSIS
        Validates the optional agents array in re-agent.config.json.
    .DESCRIPTION
        Optional matters: a config written before this slice must still load,
        so an absent key returns rather than throwing.

        level 'destructive' is rejected outright. The value exists so the
        classification can name that class of tool, not so an agent can ask
        for it. The forbidden built-ins are rejected here rather than only at
        the gate so the operator is told at load, where they can act on it.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-AgentSchema -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    if ($Config.PSObject.Properties.Name -notcontains 'agents') { return }

    $serverNames = @($Config.mcpServers | ForEach-Object { $_.name })
    $seen = @()
    foreach ($a in $Config.agents) {
        if ("$($a.name)" -notmatch '^[a-z][a-z0-9-]{2,31}$') {
            throw ("Agent name '$($a.name)' is not a valid basename. It is also the " +
                'file name and the frontmatter name:; Claude Code will not load a ' +
                'file where those disagree. Use ^[a-z][a-z0-9-]{2,31}$.')
        }
        if ($seen -contains $a.name) { throw "Agent '$($a.name)' is a duplicate name." }
        $seen += $a.name

        if ($a.level -notin @('read', 'write')) {
            throw ("Agent '$($a.name)' declares level '$($a.level)'. Valid levels are " +
                "read and write; destructive is never granted to an agent.")
        }
        foreach ($s in @($a.targetServers)) {
            if ($serverNames -notcontains $s) {
                throw ("Agent '$($a.name)' targets server '$s', which mcpServers does " +
                    "not declare. Known: [$($serverNames -join ', ')].")
            }
        }
        foreach ($b in @($a.builtinTools)) {
            if ($script:ForbiddenBuiltinTool -contains $b) {
                throw ("Agent '$($a.name)' declares built-in '$b'. Forbidden: " +
                    "[$($script:ForbiddenBuiltinTool -join ', ')].")
            }
        }
        if (-not $a.enabled -and -not "$($a.disabledReason)".Trim()) {
            throw "Agent '$($a.name)' ships disabled with no disabledReason."
        }
    }
}
```

Call it from `Test-ReAgentConfigSchema` beside the existing `Test-SkillPackSchema` call, and add
`Test-AgentSchema` to the `Export-ModuleMember` list at line 278.

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Config.psm1 tests/ReAgent.Config.Tests.ps1
git commit -m "Validate the agents block, rejecting writers and Task at load"
```

---

### Task 3: Compute an agent's tool grant

**Files:**
- Modify: `src/ReAgent.Agents.psm1`
- Test: `tests/ReAgent.Agents.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ToolClassification`, `Get-ToolLevel` (Task 1).
- Produces: `Get-AgentToolGrant -Agent <object> -Catalog <object>` →
  `[PSCustomObject]@{ Tools=[string[]]; McpCount=[int] }`. `Tools` is built-ins in declared order,
  then `mcp__<server>__<tool>` sorted by full name.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Agents.Tests.ps1`:

```powershell
Describe 'Get-AgentToolGrant' {
    function Get-GrantAgent {
        param($Level = 'read', $Servers = @('pyghidra-mcp'), $Builtins = @('Read', 'Glob', 'Grep'))
        [PSCustomObject]@{ name = 'verifier'; enabled = $true; level = $Level
            targetServers = $Servers; builtinTools = $Builtins }
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
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Get-AgentToolGrant` is not recognized.

- [ ] **Step 3: Implement it**

Add to `src/ReAgent.Agents.psm1` and to its `Export-ModuleMember`:

```powershell
function Get-AgentToolGrant {
    <#
    .SYNOPSIS
        Derives the concrete tool list one agent receives.
    .DESCRIPTION
        Derived from the catalog, never hand-listed (spec 1.3.1). An agent at
        level write receives read + write; at read, only read. destructive is
        granted to nobody at any level, so it is filtered unconditionally
        rather than by comparing against the agent's level.

        A target server with no classification contributes nothing rather than
        contributing everything. Check A1 reports that separately - silence
        here plus a finding there is what makes the gate fail closed instead
        of shipping an unjudged grant.

        Ordering is total: built-ins in declared order, then MCP tools sorted
        by full prefixed name. Spec 1.3.4 wants a re-run to reproduce the file
        byte for byte, which incidental ordering would break.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [PSCustomObject] Tools, McpCount.
    .EXAMPLE
        Get-AgentToolGrant -Agent $a -Catalog (Get-ToolCatalog)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $allowed = if ($Agent.level -eq 'write') { @('read', 'write') } else { @('read') }
    $mcp = @()
    foreach ($server in @($Agent.targetServers)) {
        $class = Get-ToolClassification -Catalog $Catalog -Server $server
        if (-not $class.Known) { continue }
        foreach ($tool in @($Catalog.servers.$server.tools)) {
            $level = Get-ToolLevel -Classification $class -Tool $tool
            if ($level -eq 'destructive') { continue }
            if ($allowed -notcontains $level) { continue }
            $mcp += "mcp__${server}__${tool}"
        }
    }
    $mcp = @($mcp | Sort-Object)
    return [PSCustomObject]@{
        Tools    = @(@($Agent.builtinTools) + $mcp)
        McpCount = $mcp.Count
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Agents.psm1 tests/ReAgent.Agents.Tests.ps1
git commit -m "Derive each agent's tool grant from the classified catalog"
```

---

### Task 4: The gate — checks A0 through A3

**Files:**
- Modify: `src/ReAgent.Agents.psm1`
- Test: `tests/ReAgent.Agents.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ToolClassification`, `Get-ToolLevel`, `Get-AgentToolGrant`.
- Produces:
  - `Test-AgentNameCheck -Frontmatter <hashtable> -FileBaseName <string> -ConfigName <string>` → `[array]` `{Check='A0'}`
  - `Test-AgentCatalogCheck -Agent <object> -Catalog <object>` → `[array]` `{Check='A1'}`
  - `Test-AgentToolExistenceCheck -GrantedTools <string[]> -Catalog <object>` → `[array]` `{Check='A2'}`
  - `Test-AgentLevelCheck -Agent <object> -GrantedTools <string[]> -Catalog <object>` → `[array]` `{Check='A3'}`
  - `Invoke-AgentGate -Agent <object> -Catalog <object> -Frontmatter <hashtable> -FileBaseName <string>` → `[array]` of all findings

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Agents.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: FAIL — the five functions are not recognized.

- [ ] **Step 3: Implement the checks**

Add to `src/ReAgent.Agents.psm1` and its `Export-ModuleMember`:

```powershell
function Test-AgentNameCheck {
    <#
    .SYNOPSIS
        Runs check A0: frontmatter name, file basename and config name agree.
    .DESCRIPTION
        Claude Code keys an agent's identity off all three. A disagreement
        means the file does not load, which presents as "the agent ignored its
        tools" rather than as an error - so it is checked before anything else.
    .PARAMETER Frontmatter
        Parsed frontmatter of the generated agent file.
    .PARAMETER FileBaseName
        The file's basename without .md.
    .PARAMETER ConfigName
        The name declared in re-agent.config.json.
    .OUTPUTS
        [array] Zero or one {Check='A0'; Message} findings.
    .EXAMPLE
        Test-AgentNameCheck -Frontmatter $fm -FileBaseName 'verifier' -ConfigName 'verifier'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Frontmatter,
        [Parameter(Mandatory)][string]$FileBaseName,
        [Parameter(Mandatory)][string]$ConfigName
    )

    $fm = "$($Frontmatter['name'])"
    if ($fm -eq $FileBaseName -and $fm -eq $ConfigName) { return @() }
    return @([PSCustomObject]@{ Check = 'A0'; Message = (
                "Agent identity disagrees: frontmatter '$fm', file '$FileBaseName', " +
                "config '$ConfigName'. Claude Code will not load this agent.") })
}

function Test-AgentCatalogCheck {
    <#
    .SYNOPSIS
        Runs check A1: every target server must have a classified catalog entry.
    .DESCRIPTION
        Without one, A2 and A3 cannot judge a single tool from that server, so
        the gap is reported rather than passed over in silence. This is what
        makes an uncaptured server (x64dbg, Binary Ninja) fail closed instead
        of yielding an empty grant that looks like a working agent.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A1'; Message} finding per unjudgeable server.
    .EXAMPLE
        Test-AgentCatalogCheck -Agent $a -Catalog (Get-ToolCatalog)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $findings = @()
    foreach ($server in @($Agent.targetServers)) {
        if ((Get-ToolClassification -Catalog $Catalog -Server $server).Known) { continue }
        $findings += [PSCustomObject]@{ Check = 'A1'; Message = (
                "Agent '$($Agent.name)' targets '$server', which has no classified " +
                'catalog entry. Capture it with .\Install-REAgent.ps1 -Attended ' +
                "-UpdateToolCatalog and classify it, or ship this agent disabled.") }
    }
    return $findings
}

function Test-AgentToolExistenceCheck {
    <#
    .SYNOPSIS
        Runs check A2: every granted MCP tool exists in the catalog.
    .DESCRIPTION
        Built-ins are skipped: they are not catalog tools and A3 judges them.
        A granted name the server does not advertise means the generator built
        it from something other than the catalog, which is the defect spec
        1.3.1 exists to prevent.
    .PARAMETER GrantedTools
        The agent's full tool list, built-ins included.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A2'; Message} finding per absent tool.
    .EXAMPLE
        Test-AgentToolExistenceCheck -GrantedTools $g.Tools -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$GrantedTools,
        [Parameter(Mandatory)][object]$Catalog
    )

    $findings = @()
    foreach ($granted in $GrantedTools) {
        if ($granted -notmatch '^mcp__(?<server>[^_]+(?:[^_]|_(?!_))*)__(?<tool>.+)$') { continue }
        $server = $Matches['server']
        $tool = $Matches['tool']
        if ($Catalog.servers.PSObject.Properties.Name -notcontains $server) { continue }
        if (@($Catalog.servers.$server.tools) -contains $tool) { continue }
        $findings += [PSCustomObject]@{ Check = 'A2'; Message = (
                "Granted '$granted', which '$server' does not advertise. The grant was " +
                'not derived from the catalog.') }
    }
    return $findings
}

function Test-AgentLevelCheck {
    <#
    .SYNOPSIS
        Runs check A3: no tool above the agent's level, no forbidden built-in.
    .DESCRIPTION
        This is the check that carries DEPLOYMENT_PLAN Phase 7's line. For the
        verifier it reduces to: nothing in write, nothing in destructive, no
        built-in writer. If A3 passes and the file still grants a writer, the
        generator is wrong, not the gate.

        destructive is rejected for every agent regardless of level - no level
        admits it.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER GrantedTools
        The agent's full tool list, built-ins included.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A3'; Message} finding per over-grant.
    .EXAMPLE
        Test-AgentLevelCheck -Agent $a -GrantedTools $g.Tools -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$GrantedTools,
        [Parameter(Mandatory)][object]$Catalog
    )

    $allowed = if ($Agent.level -eq 'write') { @('read', 'write') } else { @('read') }
    $findings = @()
    foreach ($granted in $GrantedTools) {
        if ($script:ForbiddenAgentBuiltin -contains $granted) {
            $findings += [PSCustomObject]@{ Check = 'A3'; Message = (
                    "Agent '$($Agent.name)' is granted built-in '$granted', which no " +
                    'agent may hold.') }
            continue
        }
        if ($granted -notmatch '^mcp__(?<server>[^_]+(?:[^_]|_(?!_))*)__(?<tool>.+)$') { continue }
        $class = Get-ToolClassification -Catalog $Catalog -Server $Matches['server']
        if (-not $class.Known) { continue }
        $level = Get-ToolLevel -Classification $class -Tool $Matches['tool']
        if ($level -ne 'destructive' -and $allowed -contains $level) { continue }
        $findings += [PSCustomObject]@{ Check = 'A3'; Message = (
                "Agent '$($Agent.name)' declares level '$($Agent.level)' but is granted " +
                "'$granted', classified '$level'.") }
    }
    return $findings
}

function Invoke-AgentGate {
    <#
    .SYNOPSIS
        Runs A0-A4 over one agent and returns every finding.
    .DESCRIPTION
        Runs all five rather than stopping at the first. An operator fixing a
        grant wants the whole list, not one finding per run - the same shape
        the skills gate settled on.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Frontmatter
        Parsed frontmatter of the generated file.
    .PARAMETER FileBaseName
        The generated file's basename without .md.
    .OUTPUTS
        [array] All findings, each {Check; Message}.
    .EXAMPLE
        Invoke-AgentGate -Agent $a -Catalog $cat -Frontmatter $fm -FileBaseName 'verifier'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][hashtable]$Frontmatter,
        [Parameter(Mandatory)][string]$FileBaseName
    )

    $grant = Get-AgentToolGrant -Agent $Agent -Catalog $Catalog
    $findings = @()
    $findings += Test-AgentNameCheck -Frontmatter $Frontmatter -FileBaseName $FileBaseName `
        -ConfigName "$($Agent.name)"
    $findings += Test-AgentCatalogCheck -Agent $Agent -Catalog $Catalog
    $findings += Test-AgentToolExistenceCheck -GrantedTools $grant.Tools -Catalog $Catalog
    $findings += Test-AgentLevelCheck -Agent $Agent -GrantedTools $grant.Tools -Catalog $Catalog
    foreach ($server in @($Agent.targetServers)) {
        $findings += Test-AgentClassificationCheck -Catalog $Catalog -Server $server
    }
    return $findings
}
```

Add near the top of the module, beside the other script-scope data:

```powershell
$script:ForbiddenAgentBuiltin = @('Bash', 'Write', 'Edit', 'NotebookEdit', 'Task')
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Agents.psm1 tests/ReAgent.Agents.Tests.ps1
git commit -m "Add the A0-A3 agent gate, failing closed on an over-grant"
```

---

### Task 5: The three agent templates

**Files:**
- Create: `templates/agents/static-analyst.md.template`
- Create: `templates/agents/dynamic-analyst.md.template`
- Create: `templates/agents/verifier.md.template`
- Test: `tests/ReAgent.Agents.Tests.ps1`

**Interfaces:**
- Produces: three template files carrying the tokens `{{TOOLS}}`, `{{SERVERS}}`, `{{LIMITATIONS}}`.
  Task 6 substitutes them.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Agents.Tests.ps1`:

```powershell
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
        $t.IndexOf('ai_') | Should -BeLessThan $t.IndexOf('{{TOOLS}}')
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
            (Get-Content -LiteralPath $f.FullName -Raw) | Should -BeLike '*findings*'
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `templates/agents` does not exist.

- [ ] **Step 3: Write `templates/agents/verifier.md.template`**

```markdown
---
name: verifier
description: Independently confirms or refutes findings produced by another agent. Read-only by construction. Use as the last stage of an investigation, never as the first.
tools: {{TOOLS}}
---

# Verifier

**Before anything else: when harvesting evidence, EXCLUDE every symbol whose name begins with
`ai_`.** Those names were proposed by a model, possibly by an earlier stage of this same
investigation. A read that confirms them is self-corroboration, not confirmation. If the only
support for a claim is an `ai_*` name, the claim is unverified — say so.

## What you are

You confirm or refute claims someone else made. You cannot rename, comment, retype or save, and
that is the point: a verifier that can write can make its own evidence.

## Servers you reach

{{SERVERS}}

## How to verify a claim

1. Restate the claim in terms of what would have to be true in the binary.
2. Gather evidence for it, ignoring every `ai_*` symbol.
3. Report one of: **confirmed** (with the evidence), **refuted** (with the contradiction), or
   **unverified** (say what you could not reach and why).

"Unverified" is a real result. Prefer it to a confirmation you cannot support.

## Reporting

Stamp every finding with `verifier` and the tool calls behind it, so a reader can tell which
agent produced which claim and re-run the evidence.

## Limitations

{{LIMITATIONS}}
```

- [ ] **Step 4: Write `templates/agents/static-analyst.md.template`**

```markdown
---
name: static-analyst
description: Reverse-engineers a binary without running it — decompilation, cross-references, strings, call graphs. Use for the first pass over an unknown binary.
tools: {{TOOLS}}
---

# Static analyst

You reverse-engineer binaries without executing them.

## Servers you reach

{{SERVERS}}

## Naming convention

When you propose a name for a function or variable, prefix it `ai_`. That prefix is what lets the
verifier tell your inferences apart from ground truth. Do not strip it, and do not apply it to a
name you read out of a symbol table or PDB.

## Reporting

Stamp every finding with `static-analyst` and the tool calls behind it.

## Limitations

{{LIMITATIONS}}

You have no `Bash`. The `ghidra-iterative-re` skill's `scripts/msvc_demangle` therefore cannot run
in this context — demangle by hand, or ask the main session to run it. Do not report the skill as
broken; it is a deliberate consequence of your tool grant.
```

- [ ] **Step 5: Write `templates/agents/dynamic-analyst.md.template`**

```markdown
---
name: dynamic-analyst
description: Analyses crash dumps and live debugger sessions. Use when a question needs runtime state rather than static structure.
tools: {{TOOLS}}
---

# Dynamic analyst

You analyse binaries through a debugger — crash dumps first, live sessions where the case needs it.

## Servers you reach

{{SERVERS}}

## TTD replay is not available on this host

DEPLOYMENT_PLAN §D1 prefers record-then-query. It does not work here: the in-box `dbgeng.dll`
rejects `.run` replay with `0x80070057` and has no `!analyze`. That is why `windbg-ttd` ships
disabled. Report this limitation if a case needs replay — do not spend the case rediscovering it.

## Naming convention

Prefix any name you propose with `ai_`, so the verifier can tell your inferences from ground truth.

## Reporting

Stamp every finding with `dynamic-analyst` and the tool calls behind it.

## Limitations

{{LIMITATIONS}}
```

- [ ] **Step 6: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Agents.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add templates/agents tests/ReAgent.Agents.Tests.ps1
git commit -m "Add the three agent templates, verifier leading with ai_ exclusion"
```

---

### Task 6: Generate the agent files

**Files:**
- Modify: `src/ReAgent.Generate.psm1` (add `Write-AgentDefinition`, call from `Write-AgentConfiguration`, extend `Export-ModuleMember` at line 214)
- Test: `tests/ReAgent.Generate.Tests.ps1`

**Interfaces:**
- Consumes: `Get-AgentToolGrant` (Task 3), the templates (Task 5), `Write-FileIfChanged` from
  `ReAgent.Common.psm1`.
- Produces: `Write-AgentDefinition -Config <object> -Catalog <object> -RepoRoot <string> -AgentDir <string>`
  → `[array]` of `[PSCustomObject]@{ Name; Enabled; DisabledReason; Level; Servers; ToolCount; Path; Changed }`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Generate.Tests.ps1`:

```powershell
Describe 'Write-AgentDefinition' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("agt-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Cat = [PSCustomObject]@{ servers = [PSCustomObject]@{
                'pyghidra-mcp' = [PSCustomObject]@{
                    tools = @('decompile_function', 'rename_function')
                    classification = [PSCustomObject]@{
                        classifiedTools = @('decompile_function', 'rename_function')
                        write = @('rename_function'); destructive = @() } } } }
        $script:Cfg = [PSCustomObject]@{ agents = @(
                [PSCustomObject]@{ name = 'verifier'; enabled = $true; level = 'read'
                    targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Glob', 'Grep')
                    model = 'inherit'; disabledReason = '' }) }
        $script:Root = Join-Path $PSScriptRoot '..'
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes one file per enabled agent, named for the agent' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeTrue
    }

    It 'substitutes the derived tool list into the frontmatter' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $t = Get-Content -LiteralPath (Join-Path $script:Dir 'verifier.md') -Raw
        $t | Should -BeLike '*mcp__pyghidra-mcp__decompile_function*'
        $t | Should -Not -BeLike '*rename_function*'
        $t | Should -Not -BeLike '*{{TOOLS}}*'
    }

    It 'writes nothing on a second run and reports no change' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $second = Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat `
            -RepoRoot $script:Root -AgentDir $script:Dir
        # Spec 1.3.4: byte-identical regeneration, no timestamp churn.
        @($second | Where-Object { $_.Changed }).Count | Should -Be 0
    }

    It 'does not write a disabled agent, but still reports it' {
        $script:Cfg.agents[0].enabled = $false
        $script:Cfg.agents[0].disabledReason = 'no oracle yet'
        $r = Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat `
            -RepoRoot $script:Root -AgentDir $script:Dir
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeFalse
        $r[0].Enabled | Should -BeFalse
        $r[0].DisabledReason | Should -Be 'no oracle yet'
    }

    It 'leaves an agent file this installer did not write alone' {
        # The skills slice shipped exactly this defect against a shared root and had
        # to fix it: removal is scoped to names this config knows.
        $foreign = Join-Path $script:Dir 'operators-own.md'
        Set-Content -LiteralPath $foreign -Value 'not ours' -NoNewline
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path $foreign | Should -BeTrue
    }

    It 'removes a file for an agent this config used to declare and no longer enables' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $script:Cfg.agents[0].enabled = $false
        $script:Cfg.agents[0].disabledReason = 'turned off'
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Write-AgentDefinition` is not recognized.

- [ ] **Step 3: Implement it**

Add to `src/ReAgent.Generate.psm1`. The module must import `ReAgent.Agents.psm1` for
`Get-AgentToolGrant`; follow the import style already at the top of the file.

```powershell
function Write-AgentDefinition {
    <#
    .SYNOPSIS
        Generates one agent file per enabled agent, from template plus catalog.
    .DESCRIPTION
        Written through Write-FileIfChanged so a steady-state run touches no
        timestamp - the lesson from the launcher-rewrite regression, where
        unconditional writes made a staleness check fire on every run.

        Removal is scoped to names this config declares. The .claude/agents
        directory is shared and may hold files this installer never wrote;
        deleting by "not in my wanted list" against a shared root is the defect
        the skills slice shipped and had to fix.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root, for locating templates/agents.
    .PARAMETER AgentDir
        Destination directory, normally <agentRoot>\.claude\agents.
    .OUTPUTS
        [array] One record per declared agent.
    .EXAMPLE
        Write-AgentDefinition -Config $cfg -Catalog $cat -RepoRoot $root -AgentDir $d
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AgentDir
    )

    if ($Config.PSObject.Properties.Name -notcontains 'agents') { return @() }
    if (-not (Test-Path -LiteralPath $AgentDir)) {
        New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
    }

    $results = @()
    foreach ($agent in $Config.agents) {
        $path = Join-Path $AgentDir "$($agent.name).md"
        $grant = Get-AgentToolGrant -Agent $agent -Catalog $Catalog

        if (-not $agent.enabled) {
            if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove')) {
                Remove-Item -LiteralPath $path -Force
            }
            $results += [PSCustomObject]@{ Name = $agent.name; Enabled = $false
                DisabledReason = "$($agent.disabledReason)"; Level = $agent.level
                Servers = @($agent.targetServers); ToolCount = 0; Path = $path; Changed = $false }
            continue
        }

        $tpl = Join-Path $RepoRoot "templates\agents\$($agent.name).md.template"
        if (-not (Test-Path -LiteralPath $tpl)) {
            throw ("No template at '$tpl' for agent '$($agent.name)'. Every declared " +
                'agent needs one; agent bodies are authored here, not vendored.')
        }
        $text = Get-Content -LiteralPath $tpl -Raw
        $text = $text.Replace('{{TOOLS}}', ($grant.Tools -join ', '))
        $text = $text.Replace('{{SERVERS}}', (Get-AgentServerProse -Agent $agent -Grant $grant))
        $text = $text.Replace('{{LIMITATIONS}}',
            (Get-AgentLimitationProse -Agent $agent -Catalog $Catalog))

        $changed = Write-FileIfChanged -Path $path -Text $text
        $results += [PSCustomObject]@{ Name = $agent.name; Enabled = $true
            DisabledReason = ''; Level = $agent.level; Servers = @($agent.targetServers)
            ToolCount = $grant.Tools.Count; Path = $path; Changed = $changed }
    }
    return $results
}

function Get-AgentServerProse {
    <#
    .SYNOPSIS
        Renders the {{SERVERS}} block: one line per target server.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Grant
        From Get-AgentToolGrant.
    .OUTPUTS
        [string] Markdown list.
    .EXAMPLE
        Get-AgentServerProse -Agent $a -Grant $g
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Grant
    )

    $lines = @()
    foreach ($s in @($Agent.targetServers)) {
        $n = @($Grant.Tools | Where-Object { $_ -like "mcp__${s}__*" }).Count
        $lines += "- ``$s`` — $n tool(s) at level ``$($Agent.level)``."
    }
    if (-not $lines) { $lines = @('- None. This agent has no MCP reach.') }
    return ($lines -join "`n")
}

function Get-AgentLimitationProse {
    <#
    .SYNOPSIS
        Renders the {{LIMITATIONS}} block from what the catalog cannot judge.
    .DESCRIPTION
        A target server with no classified catalog entry contributes a line, so
        the agent states the gap rather than presenting an empty reach as a
        working one. This is the prose half of check A1.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [string] Markdown list.
    .EXAMPLE
        Get-AgentLimitationProse -Agent $a -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $lines = @()
    foreach ($s in @($Agent.targetServers)) {
        if ((Get-ToolClassification -Catalog $Catalog -Server $s).Known) { continue }
        $lines += ("- ``$s`` is declared but not captured, so you hold no tools for it. " +
            'Report this rather than working around it.')
    }
    $lines += ('- A tool you expect and cannot see is your grant, not a broken server. ' +
        'The remedy is a config change plus an installer re-run — never a workaround.')
    return ($lines -join "`n")
}
```

Then call it from `Write-AgentConfiguration` (phase 4 already owns this job, so no new phase id),
passing `Get-ToolCatalog` and the agent directory, and add the three functions to
`Export-ModuleMember` at line 214.

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Generate.psm1 tests/ReAgent.Generate.Tests.ps1
git commit -m "Generate agent files from template and derived grant"
```

---

### Task 7: The routing contract in CLAUDE.md

**Files:**
- Modify: `templates/CLAUDE.md.template` (add `## Agents` after the existing `## Skills` at line 42)
- Test: `tests/ReAgent.Generate.Tests.ps1`

**Interfaces:**
- Consumes: nothing. This is static template prose, generated alongside `## Skills`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Generate.Tests.ps1`:

```powershell
Describe 'CLAUDE.md agents section' {
    BeforeAll {
        $script:Tpl = Get-Content -LiteralPath (
            Join-Path $PSScriptRoot '../templates/CLAUDE.md.template') -Raw
    }

    It 'has an Agents section' {
        $script:Tpl | Should -Match '(?m)^## Agents$'
    }

    It 'states that the main session routes and no agent spawns another' {
        $script:Tpl | Should -BeLike '*no agent spawns another*'
    }

    It 'states that the verifier runs last and independently' {
        $script:Tpl | Should -BeLike '*last*'
        $script:Tpl | Should -BeLike '*ai_*'
    }

    It 'tells the reader a missing tool is a grant, not a broken server' {
        $script:Tpl | Should -BeLike '*not a broken server*'
    }

    It 'keeps CLAUDE.md winning over any agent that contradicts it' {
        $script:Tpl | Should -BeLike '*CLAUDE.md wins*'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1 -Output Detailed"
```
Expected: FAIL on the `## Agents` match.

- [ ] **Step 3: Add the section**

`templates/CLAUDE.md.template` is an existing file on `Z:` — patch it with a Python script rather
than `Edit`. Insert after the `## Skills` block:

```markdown
## Agents

- Three specialists live under .claude/agents/. **You route; no agent spawns another.** None of
  them holds `Task`, so fan-out is yours to drive from this session.
- `static-analyst` — decompilation and structure, may rename and comment.
- `dynamic-analyst` — dumps and debugger sessions. TTD replay does not work on this host.
- `verifier` — read-only by construction. Run it **last and independently**, after a finding
  exists. It excludes every `ai_*` symbol when harvesting evidence, because confirming a name a
  model proposed is self-corroboration, not confirmation. That exclusion is the only reason its
  confirmation counts for anything.
- An agent reporting a tool it cannot see has hit its grant, **not a broken server**. The remedy
  is a config change plus an installer re-run — never a workaround.
- Findings carry the name of the agent that produced them, and the tool calls behind them.
- Where a skill or an agent conflicts with this file, **CLAUDE.md wins** and the conflict is
  reported as a finding.
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates/CLAUDE.md.template tests/ReAgent.Generate.Tests.ps1
git commit -m "Give CLAUDE.md the agent routing contract"
```

---

### Task 8: Manifest and verification wiring

**Files:**
- Modify: `src/ReAgent.Manifest.psm1` (add `Get-RecordedAgentResult`, extend `Write-Manifest`)
- Modify: `src/ReAgent.Verify.psm1` (run the gate in phase 6)
- Modify: `Install-REAgent.ps1:116-119` (phase 4) and `:125-141` (phase 6)
- Test: `tests/ReAgent.Manifest.Tests.ps1`, `tests/ReAgent.Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Invoke-AgentGate` (Task 4), `Write-AgentDefinition` (Task 6).
- Produces: `Get-RecordedAgentResult -Config <object>` → `[array]` of the same record shape
  `Write-AgentDefinition` returns, replayed from `manifest.json`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Manifest.Tests.ps1`:

```powershell
Describe 'Get-RecordedAgentResult' {
    It 'returns nothing for a config with no agents key' {
        # StrictMode: the same defect Get-RecordedSkillResult hit.
        { Get-RecordedAgentResult -Config ([PSCustomObject]@{}) } | Should -Not -Throw
    }

    It 'replays name, level, servers and tool count from the manifest' {
        $cfg = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'verifier' }) }
        $man = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'verifier'
                    enabled = $true; level = 'read'; servers = @('pyghidra-mcp')
                    toolCount = 15; gate = 'pass'; disabledReason = '' }) }
        $r = Get-RecordedAgentResult -Config $cfg -Manifest $man
        $r[0].ToolCount | Should -Be 15
        $r[0].Level | Should -Be 'read'
    }

    It 'drops an agent the current config no longer declares' {
        $cfg = [PSCustomObject]@{ agents = @() }
        $man = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'gone'
                    enabled = $true; level = 'read'; servers = @(); toolCount = 1
                    gate = 'pass'; disabledReason = '' }) }
        @(Get-RecordedAgentResult -Config $cfg -Manifest $man).Count | Should -Be 0
    }
}
```

Append to `tests/ReAgent.Verify.Tests.ps1`:

```powershell
Describe 'agent gate inside verification' {
    It 'runs the gate with nothing installed, reading only repo files' {
        # Spec 8: all five checks read only the repo and generated files, so
        # -VerifyOnly works on a host where phase 4 has never run.
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            agents = @([PSCustomObject]@{ name = 'verifier'; enabled = $true
                    level = 'read'; targetServers = @('pyghidra-mcp')
                    builtinTools = @('Read'); disabledReason = '' }) }
        $r = Invoke-AgentVerification -Config $cfg -Catalog (Get-ToolCatalog) `
            -AgentDir (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist')
        $r.Status | Should -Be 'pass'
    }

    It 'fails verification when an agent is over-granted' {
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            agents = @([PSCustomObject]@{ name = 'verifier'; enabled = $true
                    level = 'read'; targetServers = @('nonexistent-server')
                    builtinTools = @('Read'); disabledReason = '' }) }
        $r = Invoke-AgentVerification -Config $cfg -Catalog (Get-ToolCatalog) `
            -AgentDir (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist')
        $r.Status | Should -Be 'failed'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Manifest.Tests.ps1,tests/ReAgent.Verify.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Get-RecordedAgentResult` and `Invoke-AgentVerification` are not recognized.

- [ ] **Step 3: Implement `Get-RecordedAgentResult`**

Add to `src/ReAgent.Manifest.psm1` beside `Get-RecordedSkillResult` (line 313), and to its
`Export-ModuleMember`:

```powershell
function Get-RecordedAgentResult {
    <#
    .SYNOPSIS
        Replays the last run's agent results out of manifest.json.
    .DESCRIPTION
        Mirrors Get-RecordedSkillResult: -VerifyOnly cannot produce its own
        generation results, so verification reads back what the last real run
        recorded, and says nothing at all when there was none.

        Agents the current config no longer declares are dropped: the manifest
        describes a past run, and the config is what is being verified now.
        Every field comes from the recorded entry rather than from the config
        block - a config edit since then must not silently overwrite what was
        actually generated.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Manifest
        The parsed manifest. Defaults to reading it from the state root.
    .OUTPUTS
        [array] One record per still-declared agent.
    .EXAMPLE
        Get-RecordedAgentResult -Config $cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [object]$Manifest = $null
    )

    # 'agents' is an optional top-level key, so a config written before this
    # slice must not throw under StrictMode.
    if ($Config.PSObject.Properties.Name -notcontains 'agents') { return @() }
    if ($null -eq $Manifest) { $Manifest = Read-Manifest -Config $Config }
    if ($null -eq $Manifest) { return @() }
    if ($Manifest.PSObject.Properties.Name -notcontains 'agents') { return @() }

    $declared = @($Config.agents | ForEach-Object { $_.name })
    $results = @()
    foreach ($entry in $Manifest.agents) {
        if ($declared -notcontains $entry.name) { continue }
        $results += [PSCustomObject]@{
            Name = $entry.name; Enabled = [bool]$entry.enabled
            DisabledReason = "$($entry.disabledReason)"; Level = "$($entry.level)"
            Servers = @($entry.servers); ToolCount = [int]$entry.toolCount
            Path = ''; Changed = $false; Gate = "$($entry.gate)"
        }
    }
    return $results
}
```

Use whatever the module already calls to load `manifest.json` in place of `Read-Manifest` if that
helper has a different name — read `Get-RecordedSkillResult`'s body and match it exactly.

Then extend `Write-Manifest` to emit the `agents[]` block from `$Context.AgentResults`:

```powershell
    agents = @($Context.AgentResults | ForEach-Object {
            [ordered]@{ name = $_.Name; enabled = $_.Enabled
                disabledReason = $_.DisabledReason; level = $_.Level
                servers = @($_.Servers); toolCount = $_.ToolCount
                gate = $(if ($_.PSObject.Properties.Name -contains 'Gate') { $_.Gate }
                    else { 'pass' }) } })
```

- [ ] **Step 4: Implement `Invoke-AgentVerification`**

Add to `src/ReAgent.Verify.psm1` and its `Export-ModuleMember`. It reads only repo files and any
generated agent file, so it runs under `-VerifyOnly` on a host where phase 4 never ran:

```powershell
function Invoke-AgentVerification {
    <#
    .SYNOPSIS
        Runs the A0-A4 gate over every enabled agent.
    .DESCRIPTION
        Reads only the repo and the generated files, so all five checks run on
        every verification including -VerifyOnly on a host where the generation
        phase has never run (spec 8). A missing agent file is not itself a
        failure here - the gate judges the grant the config and catalog imply,
        which is what would be generated.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER AgentDir
        Where generated agent files live. May not exist.
    .OUTPUTS
        [PSCustomObject] Name, Status, Findings.
    .EXAMPLE
        Invoke-AgentVerification -Config $cfg -Catalog $cat -AgentDir $d
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$AgentDir
    )

    if ($Config.PSObject.Properties.Name -notcontains 'agents') {
        return [PSCustomObject]@{ Name = 'agents'; Status = 'not-testable'
            Findings = @(); Reason = 'This config declares no agents.' }
    }

    $findings = @()
    foreach ($agent in @($Config.agents | Where-Object { $_.enabled })) {
        $path = Join-Path $AgentDir "$($agent.name).md"
        # No file yet means nothing has been generated; judge the grant the
        # config implies, using the name the generator would write.
        $fm = @{ name = "$($agent.name)" }
        if (Test-Path -LiteralPath $path) {
            $fm = Get-SkillFrontmatter -Path $path
        }
        $findings += Invoke-AgentGate -Agent $agent -Catalog $Catalog `
            -Frontmatter $fm -FileBaseName "$($agent.name)"
    }

    return [PSCustomObject]@{
        Name     = 'agents'
        Status   = $(if ($findings.Count) { 'failed' } else { 'pass' })
        Findings = $findings
    }
}
```

`Get-SkillFrontmatter` is already exported from `ReAgent.Skills.psm1` and the frontmatter format is
identical, so it is reused rather than duplicated.

- [ ] **Step 5: Wire the phases**

In `Install-REAgent.ps1`, phase 4 at line 116 already calls `Write-AgentConfiguration`, which now
generates the agent files — capture its agent records onto the context:

```powershell
    @{ Id   = 4; Name = 'AgentConfig'
        Test = { $false }
        Fn   = { param($c) $c.AgentResults = @(Write-AgentConfiguration -Config $c.Config `
                    -ServerResults $c.ServerResults -RepoRoot $PSScriptRoot) }
    }
```

In phase 6 at line 125, replay from the manifest when phase 4 did not run, exactly as the existing
server and skill replays do:

```powershell
            if (-not $c.AgentResults -or $c.AgentResults.Count -eq 0) {
                $c.AgentResults = @(Get-RecordedAgentResult -Config $c.Config)
            }
```

and pass `-AgentResults $c.AgentResults` into `Invoke-Verification`. Add `AgentResults = @()` to the
context hashtable initialised above line 95.

- [ ] **Step 6: Run the full suite**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; \$c = New-PesterConfiguration; \$c.Run.Path='tests'; \$c.Run.PassThru=\$true; \$c.Output.Verbosity='None'; \$r = Invoke-Pester -Configuration \$c; Write-Host \"PASSED=\$(\$r.PassedCount) FAILED=\$(\$r.FailedCount)\""
```
Expected: `FAILED=0`.

- [ ] **Step 7: Commit**

```bash
git add src/ReAgent.Manifest.psm1 src/ReAgent.Verify.psm1 Install-REAgent.ps1 tests/
git commit -m "Record agents in the manifest and gate them during verify"
```

---

### Task 9: Declare the three agents and prove idempotency end to end

**Files:**
- Modify: `re-agent.config.json`
- Modify: `docs/superpowers/specs/2026-09-07-agent-topology-design.md` (§12, the OQ1 gap)
- Test: `tests/Integration.Tests.ps1`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Add the agents block to the config**

Patch `re-agent.config.json` with a Python script (existing file on `Z:`). Per **OQ1**, the verifier
targets `pyghidra-mcp` only; per spec §12 gap 7, `dynamic-analyst` ships disabled because no
`x64dbg` capture exists:

```json
"agents": [
  { "name": "static-analyst", "enabled": true, "level": "write",
    "targetServers": ["pyghidra-mcp"], "builtinTools": ["Read", "Glob", "Grep"],
    "model": "inherit", "disabledReason": "" },
  { "name": "dynamic-analyst", "enabled": false, "level": "write",
    "targetServers": ["mcp-windbg"], "builtinTools": ["Read", "Glob", "Grep"],
    "model": "inherit",
    "disabledReason": "x64dbg's tool surface is not captured, so its half of this agent cannot be derived; enable after an attended -UpdateToolCatalog run" },
  { "name": "verifier", "enabled": true, "level": "read",
    "targetServers": ["pyghidra-mcp"], "builtinTools": ["Read", "Glob", "Grep"],
    "model": "inherit", "disabledReason": "" }
]
```

`static-analyst` drops `binaryninja` for the same reason `dynamic-analyst` ships disabled — A1
would fail on it. Record that in the commit message.

- [ ] **Step 2: Write the failing integration tests**

Append to `tests/Integration.Tests.ps1`:

```powershell
Describe 'agent topology end to end' {
    BeforeAll {
        $script:Cfg = Get-ReAgentConfig -Path (Join-Path $PSScriptRoot '../re-agent.config.json')
        $script:Cat = Get-ToolCatalog
    }

    It 'loads a config declaring three agents' {
        @($script:Cfg.agents).Count | Should -Be 3
    }

    It 'passes the gate for every enabled agent' {
        foreach ($a in @($script:Cfg.agents | Where-Object { $_.enabled })) {
            $g = Get-AgentToolGrant -Agent $a -Catalog $script:Cat
            Invoke-AgentGate -Agent $a -Catalog $script:Cat `
                -Frontmatter @{ name = $a.name } -FileBaseName $a.name |
                Should -BeNullOrEmpty -Because "agent '$($a.name)' must pass A0-A4"
        }
    }

    It 'grants the verifier no tool classified write or destructive' {
        # DEPLOYMENT_PLAN Phase 7: if the verifier can write, it isn't a verifier.
        $v = @($script:Cfg.agents | Where-Object { $_.name -eq 'verifier' })[0]
        $g = Get-AgentToolGrant -Agent $v -Catalog $script:Cat
        foreach ($t in $g.Tools) {
            if ($t -notmatch '^mcp__(?<s>.+?)__(?<t>.+)$') { continue }
            $c = Get-ToolClassification -Catalog $script:Cat -Server $Matches['s']
            Get-ToolLevel -Classification $c -Tool $Matches['t'] | Should -Be 'read'
        }
    }

    It 'grants the static analyst write but never destructive' {
        $s = @($script:Cfg.agents | Where-Object { $_.name -eq 'static-analyst' })[0]
        $g = Get-AgentToolGrant -Agent $s -Catalog $script:Cat
        $g.Tools | Should -Contain 'mcp__pyghidra-mcp__rename_function'
        $g.Tools | Should -Not -Contain 'mcp__pyghidra-mcp__delete_project_binary'
    }

    It 'regenerates byte-identical files on a second run' {
        # Spec 1.3.4.
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("idem-" + [guid]::NewGuid())
        try {
            $root = Join-Path $PSScriptRoot '..'
            Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $root `
                -AgentDir $dir | Out-Null
            $before = @(Get-ChildItem $dir -Filter '*.md' | ForEach-Object {
                    (Get-FileHash $_.FullName -Algorithm SHA256).Hash })
            $second = Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat `
                -RepoRoot $root -AgentDir $dir
            $after = @(Get-ChildItem $dir -Filter '*.md' | ForEach-Object {
                    (Get-FileHash $_.FullName -Algorithm SHA256).Hash })
            ($after -join ',') | Should -Be ($before -join ',')
            @($second | Where-Object { $_.Changed }).Count | Should -Be 0
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'writes no file for the disabled dynamic analyst but records its reason' {
        $d = @($script:Cfg.agents | Where-Object { $_.name -eq 'dynamic-analyst' })[0]
        $d.enabled | Should -BeFalse
        "$($d.disabledReason)".Trim() | Should -Not -BeNullOrEmpty
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/Integration.Tests.ps1 -Output Detailed"
```
Expected: FAIL — the config has no `agents` key yet if Step 1 was deferred, otherwise FAIL on the
first assertion that exposes a real gap.

- [ ] **Step 4: Apply Step 1's config patch and re-run**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/Integration.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Record the OQ1 outcome in the spec**

Add a row to spec §12: the verifier reaches `pyghidra-mcp` only, because `mcp-windbg`'s query tools
are unconstrained and classifying them `read` would defeat A3. Fixed additively by a read-only
dump-query tool, exactly like gap 1's oracle.

- [ ] **Step 6: Run the full suite and the analyzer**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; \$c = New-PesterConfiguration; \$c.Run.Path='tests'; \$c.Run.PassThru=\$true; \$c.Output.Verbosity='None'; \$r = Invoke-Pester -Configuration \$c; Write-Host \"PASSED=\$(\$r.PassedCount) FAILED=\$(\$r.FailedCount)\"; Invoke-ScriptAnalyzer -Path src,Install-REAgent.ps1 -Severity Warning,Error -Recurse"
```
Expected: `FAILED=0` and no analyzer output.

- [ ] **Step 7: Commit**

```bash
git add re-agent.config.json tests/Integration.Tests.ps1 docs/superpowers/specs/2026-09-07-agent-topology-design.md
git commit -m "Declare the three agents and prove the grants end to end"
```

---

## Spec coverage

| Spec section | Task |
|---|---|
| §1.3.1 grants derived from catalog | 1, 3, 9 |
| §1.3.2 gate fails closed | 1, 4 |
| §1.3.3 `-VerifyOnly` with no prior run | 8 |
| §1.3.4 byte-identical regeneration | 6, 9 |
| §1.3.5 manifest records each agent | 8 |
| §4 topology and grants | 9 |
| §4.1 verifier's `ai_` lead contract | 5 |
| §4.2 dynamic analyst's TTD limitation | 5 |
| §5 classification beside `tools[]` | 1 |
| §6 config schema, all six rules | 2 |
| §7 templates, phase 4, scoped removal, ordering | 3, 5, 6 |
| §8 checks A0–A4 | 1, 4 |
| §9 routing contract | 7 |
| §10 manifest, replay, idempotency | 6, 8, 9 |
| §11 all five negative tests | 1 (#3), 2 (#5), 4 (#1, #2, #4) |
| §12 gap 7 → `dynamic-analyst` disabled | 9 |

## A note for the reviewer

`$script:ForbiddenBuiltinTool` (Task 2, Config module) and `$script:ForbiddenAgentBuiltin`
(Task 4, Agents module) hold the same five names. Script scope does not cross module
boundaries, so this is duplication rather than a shared constant. Two copies is below the
rule-of-three threshold AGENTS.md sets for extracting a utility — but if a third consumer
appears, promote it to one exported function rather than adding a copy. Task 2's copy exists
to fail at config load, where the operator can act on it; Task 4's exists so the gate is
still correct if a grant reaches it by some path other than the loader.
