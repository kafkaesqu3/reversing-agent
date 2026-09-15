# Codex Workspace Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Codex project-scoped equivalents of the RE workspace contract, eleven reviewed skills, and two enabled specialists while preserving the existing Claude outputs and user-level MCP registration.

**Architecture:** Keep `ReAgent.Codex.psm1` responsible for user `config.toml` registration. Add a pure Codex content adapter, a project-workspace reconciler, and a C0-C8 verifier; both client views continue to come from the same templates, vendored skills, config, catalog, and server results. Custom-agent files contain complete deterministic transports because Codex 0.153.4 rejects partial MCP tables, but they never contain bearer values or authorization headers.

**Tech Stack:** Windows PowerShell 5.1, Pester 5.5.0+, PSScriptAnalyzer, Codex CLI 0.153.4+, JSON configuration/catalog data, Markdown/YAML frontmatter, and TOML emitted by dedicated encoders.

**Spec:** `docs/superpowers/specs/2026-09-14-codex-parity-design.md`

## Global Constraints

- **Measured gate outcome:** Codex CLI 0.153.4 rejected a custom-agent MCP table containing only `enabled` and `enabled_tools` with `invalid transport`; every emitted custom-agent server table must therefore contain its complete transport.
- **Secret boundary:** Custom-agent TOML may contain deterministic local HTTP URLs and stdio `command`, `args`, `cwd`, and non-secret environment entries derived from `ServerResults`. It must never contain bearer values, authorization headers, generated tokens, or token-bearing environment values.
- **Authenticated targets:** The current enabled Codex specialists may enable only `pyghidra-mcp` (`auth: none`) and `mcp-windbg` (`auth: none`). Generation must fail if a future enabled specialist targets a compatible server whose `auth` is not `none`.
- **Unsupported transports:** `pdbsql`, `ghidrasql`, and disabled `ghidramcp` remain legacy SSE. Omit them from custom-agent tables and record the exact reason `legacy SSE is unsupported by Codex`.
- **Scope:** Instructions, skills, and custom agents install only below `Config.paths.agentRoot`. `CodexHome` continues to select user MCP registration and must not relocate project artifacts.
- **Ownership:** Never overwrite or remove an unmarked `AGENTS.md`, skill directory, or custom-agent file. Resolve cleanup targets beneath the expected project root before deletion.
- **Existing worktree:** The MCP registration slice is present as uncommitted changes in `Install-REAgent.ps1`, `install-codex.ps1`, `src/ReAgent.Codex.psm1`, `src/ReAgent.Verify.psm1`, their tests, and docs. Preserve that work; do not reset or reconstruct it from `HEAD`.
- **PowerShell 5.1 only:** No `??`, `?:`, `ForEach-Object -Parallel`, or three-argument `Join-Path`.
- Functions remain at most 100 lines, cyclomatic complexity at most 8, with at most 5 positional parameters and 100-character source lines.
- Every exported function has comment-based help. PSScriptAnalyzer must report zero errors and warnings.
- All generated text is UTF-8 without a BOM and byte-idempotent. An unchanged run must preserve timestamps and create no backup.
- `-WhatIf` may render and validate candidates in memory but must create no destination, staging directory, marker, backup, or temporary file under `Config.paths.agentRoot` or `CodexHome`.
- Every task uses failing tests first and ends with an independently reviewable commit. Commit subjects are imperative, at most 72 characters, with no AI attribution.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/ReAgent.Codex.psm1` | Existing user-level MCP registration only; retain the current transport-aware registration work. |
| `src/ReAgent.CodexAdapter.psm1` | **Create.** Pure MCP namespace, frontmatter, workflow prose, TOML string/array, and complete transport conversion. |
| `src/ReAgent.CodexWorkspace.psm1` | **Create.** Render and reconcile project `AGENTS.md`, `.agents/skills`, and `.codex/agents` with ownership and idempotency. |
| `src/ReAgent.CodexVerify.psm1` | **Create.** Deterministic C0-C8 checks and `codex-verify-report.json` serialization. |
| `src/ReAgent.Generate.psm1` | Render Claude instructions from shared instruction templates and shared agent bodies. |
| `src/ReAgent.Skills.psm1` | Run the reviewed-source gate once, then install the Claude and Codex views independently. |
| `src/ReAgent.Config.psm1` | Validate optional exact Codex residue exceptions. |
| `src/ReAgent.Manifest.psm1` | Add `codexWorkspace` records and replay helpers without persisting secrets. |
| `templates/instructions/common.md.template` | **Create.** Client-neutral trust, tool, analysis, workflow, naming, mutation, and reporting contract. |
| `templates/instructions/claude.md.template` | **Create.** Claude discovery, invocation, and routing tail. |
| `templates/instructions/codex.md.template` | **Create.** Codex discovery, `$skill-name`, subagent routing, and SSE limitation tail. |
| `templates/CLAUDE.md.template` | **Delete after Task 2.** Replaced by the shared instruction inputs. |
| `templates/agents/*.md.template` | Keep one semantic specialist body; replace hard-coded Claude-only limitations with `{{CLIENT_LIMITATIONS}}`. |
| `tests/ReAgent.CodexAdapter.Tests.ps1` | **Create.** Pure conversion and TOML tests. |
| `tests/ReAgent.CodexWorkspace.Tests.ps1` | **Create.** Ownership, generation, skill staging, agent transport, idempotency, and WhatIf tests. |
| `tests/ReAgent.CodexVerify.Tests.ps1` | **Create.** C0-C8 pass/fail fixtures and report tests. |
| `tests/ReAgent.Generate.Tests.ps1` | Preserve the existing Claude contract after template splitting. |
| `tests/ReAgent.Skills.Tests.ps1` | Prove one gate produces set-equal independent client views. |
| `tests/ReAgent.Config.Tests.ps1` | Exact exception-schema validation. |
| `tests/ReAgent.Manifest.Tests.ps1` | `codexWorkspace` serialization and replay tests. |
| `tests/Integration.Tests.ps1` | Phase wiring, standalone parity, complete-run idempotency, VerifyOnly, and WhatIf. |
| `Install-REAgent.ps1` | Phase 4/5/6 orchestration and Codex result context. |
| `install-codex.ps1` | `-ConfigureOnly` and `-VerifyOnly` parity without Claude installation or downloads. |
| `README.md`, `docs/mvp/CODEX.md`, `docs/mvp/MVP.md`, `docs/mvp/HANDOFF.md` | Operator behavior, limitations, acceptance procedure, and final measured evidence. |

---

### Task 1: Add the pure Codex conversion boundary

**Files:**

- Create: `src/ReAgent.CodexAdapter.psm1`
- Create: `tests/ReAgent.CodexAdapter.Tests.ps1`
- Modify: `src/ReAgent.Config.psm1`
- Modify: `tests/ReAgent.Config.Tests.ps1`

**Interfaces:**

- Produces: `ConvertTo-CodexMcpNamespace -Name <string>` -> lowercase namespace string.
- Produces: `Get-CodexMcpNamespaceMap -Servers <array>` -> hashtable keyed by configured server name; throws on normalized collisions.
- Produces: `ConvertTo-CodexMcpReference -Text <string> -NamespaceMap <hashtable> -Catalog <object> -CompatibleServers <string[]>` -> structurally rewritten text; throws for unsupported/unknown servers or tools.
- Produces: `ConvertTo-CodexFrontmatter -Text <string>` -> frontmatter retaining `name`, `description`, `license`, `keywords`, and other descriptive scalar/list metadata but removing `allowed-tools`.
- Produces: `ConvertTo-CodexWorkflowText -Text <string> -SkillNames <string[]>` -> exact syntax/phrase conversions from spec section 6.4.
- Produces: `ConvertTo-CodexTomlValue -Value <string>` and `ConvertTo-CodexTomlArray -Values <string[]>` -> TOML basic string/array text.
- Produces: `New-CodexAgentServerTable -ConfigServer <object> -ServerResult <object> -Enabled <bool> -EnabledTools <string[]>` -> complete, token-free table text.
- Produces: optional `Config.skills[].codexScanExceptions[]` entries shaped `{ skill, file, ruleId, justification }`.

The accepted C4 rule IDs are `C4-CLAUDE-SKILL-PATH`, `C4-CLAUDE-AGENT-PATH`,
`C4-CLAUDE-PRECEDENCE`, `C4-TODOWRITE`, `C4-TASK-TOOL`, `C4-AGENT-TOOL`,
`C4-SKILL-TOOL`, and `C4-HYPHENATED-MCP`. Schema validation rejects every other ID.

- [ ] **Step 1: Write failing adapter tests**

Create `tests/ReAgent.CodexAdapter.Tests.ps1` with table-driven cases covering the exact contract:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexAdapter.psm1" -Force
}

Describe 'ConvertTo-CodexMcpNamespace' {
    It 'normalizes <Input> to <Expected>' -ForEach @(
        @{ Input = 'pyghidra-mcp'; Expected = 'pyghidra_mcp' }
        @{ Input = 'MCP-WinDBG'; Expected = 'mcp_windbg' }
        @{ Input = 'x64dbg---x32'; Expected = 'x64dbg_x32' }
        @{ Input = 'already_ok'; Expected = 'already_ok' }
    ) {
        ConvertTo-CodexMcpNamespace -Name $Input | Should -BeExactly $Expected
    }

    It 'rejects two configured names that normalize to one namespace' {
        { Get-CodexMcpNamespaceMap -Servers @(
                [pscustomobject]@{ name = 'a-b' },
                [pscustomobject]@{ name = 'a_b' }) } | Should -Throw '*collision*'
    }
}

Describe 'ConvertTo-CodexMcpReference' {
    It 'rewrites only an exact structured reference' {
        $map = @{ 'mcp-windbg' = 'mcp_windbg' }
        $catalog = [pscustomobject]@{ servers = [pscustomobject]@{
                'mcp-windbg' = [pscustomobject]@{ tools = @('list_dumps') } } }
        $text = 'Call mcp__mcp-windbg__list_dumps; prose mcp-windbg stays.'
        ConvertTo-CodexMcpReference -Text $text -NamespaceMap $map `
            -Catalog $catalog -CompatibleServers @('mcp-windbg') |
            Should -BeExactly 'Call mcp__mcp_windbg__list_dumps; prose mcp-windbg stays.'
    }
}

Describe 'New-CodexAgentServerTable' {
    BeforeEach {
        $httpConfig = [pscustomobject]@{ name = 'x64dbg-mcp-x64'; auth = 'bearer' }
        $httpResult = [pscustomobject]@{
            Transport = 'http'; Bind = '127.0.0.1'; Port = 8765; Path = '/mcp'
        }
        $stdioConfig = [pscustomobject]@{ name = 'mcp-windbg'; auth = 'none' }
        $stdioResult = [pscustomobject]@{
            Transport = 'stdio'
            Command = [pscustomobject]@{
                Executable = 'C:\Program Files\WinDbg MCP\server.exe'
                Arguments = @('--mode', 'read only')
                Env = [ordered]@{ RE_MODE = 'analysis'; RE_LABEL = "café" }
            }
        }
    }

    It 'emits a complete disabled authenticated HTTP table without credentials' {
        $actual = New-CodexAgentServerTable -ConfigServer $httpConfig `
            -ServerResult $httpResult -Enabled $false -EnabledTools @()
        $actual | Should -Match 'url = "http://127\.0\.0\.1:8765/mcp"'
        $actual | Should -Match 'enabled = false'
        $actual | Should -Not -Match '(?i)Authorization|Bearer|token'
    }

    It 'emits command args cwd and sorted non-secret environment for stdio' {
        $actual = New-CodexAgentServerTable -ConfigServer $stdioConfig `
            -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps')
        $actual | Should -Match 'command = "C:\\\\Program Files\\\\WinDbg MCP\\\\server\.exe"'
        $actual | Should -Match 'args = \["--mode","read only"\]'
        $actual.IndexOf('RE_LABEL') | Should -BeLessThan $actual.IndexOf('RE_MODE')
    }

    It 'rejects an enabled authenticated HTTP target' {
        { New-CodexAgentServerTable -ConfigServer $httpConfig `
                -ServerResult $httpResult -Enabled $true -EnabledTools @('read_mem') } |
            Should -Throw '*authenticated*enabled*'
    }

    It 'rejects the sensitive environment name <Name>' -ForEach @(
        @{ Name = 'API_TOKEN' }
        @{ Name = 'CLIENT_SECRET' }
        @{ Name = 'DB_PASSWORD' }
        @{ Name = 'AUTH_HEADER' }
        @{ Name = 'PRIVATE_KEY' }
    ) {
        $stdioResult.Command.Env = @{ $Name = 'fixture-sensitive-value' }
        { New-CodexAgentServerTable -ConfigServer $stdioConfig `
                -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps') } |
            Should -Throw '*environment*'
    }

    It 'escapes quotes apostrophes backslashes Unicode and newlines' {
        $value = 'quote " apostrophe '' slash \ café' + "`nnext"
        $encoded = ConvertTo-CodexTomlValue -Value $value
        $encoded | Should -BeExactly '"quote \" apostrophe '' slash \\ café\nnext"'
    }
}
```

Emit `cwd` only if a future shared `New-ServerResult` command record supplies a working-directory
property; the current record supplies only `Executable`, `Arguments`, and `Env`. Do not introduce
a second result shape solely for Codex.

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexAdapter.Tests.ps1 -Output Detailed
```

Expected: FAIL because `ReAgent.CodexAdapter.psm1` does not exist.

- [ ] **Step 3: Implement the pure namespace and TOML primitives**

Start `src/ReAgent.CodexAdapter.psm1` with the normalization and collision behavior:

```powershell
Set-StrictMode -Version Latest

function ConvertTo-CodexMcpNamespace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $value = [regex]::Replace($Name, '[^A-Za-z0-9]+', '_').Trim('_')
    $value = [regex]::Replace($value, '_+', '_').ToLowerInvariant()
    if (-not $value) { throw "MCP server name '$Name' has no alphanumeric namespace." }
    return $value
}

function ConvertTo-CodexTomlValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t')
    $escaped = $escaped.Replace("`n", '\n').Replace("`f", '\f')
    $escaped = $escaped.Replace("`r", '\r')
    if ($escaped -match '[\x00-\x07\x0B\x0E-\x1F\x7F]') {
        throw 'TOML basic strings cannot contain unencoded control characters.'
    }
    return '"' + $escaped + '"'
}
```

Use a regex match evaluator for `mcp__<server>__<tool>` references. Look up the original server in the supplied map and the bare tool in `Catalog.servers.<server>.tools` before replacing only the server segment. Do not rewrite free prose.

- [ ] **Step 4: Implement structural frontmatter and workflow conversion**

Parse the opening `---` block line-by-line. When `allowed-tools:` is encountered, drop that key and all immediately following indented list entries. Retain all other well-formed descriptive keys in original order. Apply only these reviewed conversions to active prose:

```powershell
$exact = [ordered]@{
    '.claude/skills' = '.agents/skills'
    '.claude/agents' = '.codex/agents'
    'CLAUDE.md wins' = 'AGENTS.md wins'
    'TodoWrite' = 'a concise Codex task or plan list'
    'Task tool' = 'Codex subagent collaboration'
    'Agent tool' = 'Codex subagent collaboration'
    'Skill tool' = '/skills discovery'
}
```

Convert a slash invocation only when the captured name is present in `-SkillNames`; render it as `$<name>`. Convert backticked Claude builtins only in syntactic tool-call phrases, using the wording in spec section 6.4. Leave quoted history and unrelated prose untouched for C4 to judge.

- [ ] **Step 5: Implement complete token-free transport rendering**

For HTTP, always emit `url` from `Bind`, `Port`, and `Path`. If `Enabled` and `ConfigServer.auth -ne 'none'`, throw. Never emit headers. For stdio, emit `command`, `args`, optional `cwd`, and environment entries only after rejecting names matching `(?i)(TOKEN|SECRET|PASSWORD|AUTH|KEY)`; sort environment keys. Reject SSE before rendering.

- [ ] **Step 6: Add exact Codex exception schema validation**

Extend the skill-pack schema in `ReAgent.Config.psm1` so each optional `codexScanExceptions` entry requires non-empty `skill`, normalized relative `file`, known `ruleId`, and non-empty `justification`. Reject absolute paths, `..`, wildcards, and missing fields. Add matching pass/fail cases to `tests/ReAgent.Config.Tests.ps1`.

- [ ] **Step 7: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexAdapter.Tests.ps1,tests/ReAgent.Config.Tests.ps1 -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.CodexAdapter.psm1,src/ReAgent.Config.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: all focused tests pass; analyzer prints no findings.

- [ ] **Step 8: Commit**

```powershell
git add src/ReAgent.CodexAdapter.psm1 src/ReAgent.Config.psm1 `
    tests/ReAgent.CodexAdapter.Tests.ps1 tests/ReAgent.Config.Tests.ps1
git commit -m "Add pure Codex workspace adapters"
```

---

### Task 2: Split and reconcile the shared operating contract

**Files:**

- Create: `templates/instructions/common.md.template`
- Create: `templates/instructions/claude.md.template`
- Create: `templates/instructions/codex.md.template`
- Delete: `templates/CLAUDE.md.template`
- Create: `src/ReAgent.CodexWorkspace.psm1`
- Create: `tests/ReAgent.CodexWorkspace.Tests.ps1`
- Modify: `src/ReAgent.Generate.psm1`
- Modify: `tests/ReAgent.Generate.Tests.ps1`

**Interfaces:**

- Consumes: `Write-FileIfChanged`, `ConvertTo-CodexWorkflowText`.
- Produces: `New-ClientInstructionText -TemplateRoot <string> -Client <Claude|Codex>` -> deterministic Markdown.
- Produces: `Write-CodexInstruction -Config <object> -TemplateRoot <string> [-WhatIf]` -> `{ Path, Status, Sha256, Changed }`.
- Produces: `Test-ReAgentOwnershipMarker -Path <string> -Marker <string>` -> boolean.
- Produces: `Set-ManagedTextFile -Path <string> -Text <string> -Marker <string> -BackupOnChange <bool> [-WhatIf]` -> reconciliation record.

- [ ] **Step 1: Lock the current Claude bytes in a failing regression test**

Before deleting the monolithic template, add a test that reads it as the expected baseline, renders the proposed common plus Claude tail, and requires byte equality after the repository newline convention. Add Codex assertions for the ownership marker, `.agents/skills`, `.codex/agents`, `$skill-name`, and all three SSE limitations.

- [ ] **Step 2: Add ownership refusal, backup, idempotency, and WhatIf tests**

In `tests/ReAgent.CodexWorkspace.Tests.ps1`, use `$TestDrive` roots and this exact assertion
matrix:

| Fixture | Invocation | Required assertions |
|---|---|---|
| Existing `AGENTS.md` containing only `# operator-owned` | `Set-ManagedTextFile` with the RE marker and replacement text | Throws `*unmanaged*`; SHA-256 and bytes are unchanged; no pending or backup sibling exists. |
| Existing marked file whose bytes differ | `Set-ManagedTextFile -BackupOnChange $true` | Destination equals candidate bytes; exactly one backup contains the old bytes; result status is `updated`. |
| Existing marked file whose bytes equal the candidate | Invoke the same writer twice | SHA-256 and `LastWriteTimeUtc` are unchanged; no backup exists; result status is `unchanged`. |
| Absent `AGENTS.md` and absent project root | `Write-CodexInstruction -WhatIf` | Project root, destination, pending file, and backup are all absent; result status is `what-if`. |

Calculate hashes with `Get-FileHash -Algorithm SHA256`, enumerate only the destination's parent
for pending/backup siblings, and compare `[IO.File]::ReadAllBytes` for the byte assertions.

- [ ] **Step 3: Run tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1,tests/ReAgent.CodexWorkspace.Tests.ps1 `
    -Output Detailed
```

Expected: FAIL because the split templates and workspace module do not exist.

- [ ] **Step 4: Split the template without changing Claude semantics**

Move the shared sections from `templates/CLAUDE.md.template` into `common.md.template`: Trust boundary, client-neutral tool availability, Analysis discipline, Workflow, `ai_` naming/self-corroboration, invariant bracketing, and case output. Put only Claude paths, skill precedence wording, and Claude routing in `claude.md.template`. Put the following exact Codex concepts in `codex.md.template`:

```text
- Skills are discovered under .agents/skills and invoked as $skill-name or through /skills.
- Specialists are discovered under .codex/agents; the main session routes work to them.
- AGENTS.md wins over a conflicting skill or specialist instruction.
- pdbsql and ghidrasql use legacy SSE and are unavailable to Codex.
- ghidramcp is disabled and also uses legacy SSE.
- For x64dbg, open the matching x64dbg/x32dbg host with the target loaded.
- For Binary Ninja, run Plugins > MCP > Start Server once per application session.
```

Join common and tail with exactly one blank line and one final newline.

- [ ] **Step 5: Implement managed-file reconciliation**

`Set-ManagedTextFile` must inspect ownership before `ShouldProcess`. For a changed marked file, write a same-directory unique pending file, then use `[IO.File]::Replace` with a unique backup when `BackupOnChange` is true; otherwise use a rollback-safe pending replacement. If the file is absent, move the pending file into place. Always remove only the exact pending path in `finally`.

- [ ] **Step 6: Wire both clients to the shared render**

Change `Write-AgentConfiguration` to render Claude through `New-ClientInstructionText` and `Write-FileIfChanged` instead of copying the old template. Implement `Write-CodexInstruction` with marker `<!-- re-agent-managed: codex-operating-contract v1 -->` and `BackupOnChange = $true`.

- [ ] **Step 7: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1,tests/ReAgent.CodexWorkspace.Tests.ps1 `
    -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.Generate.psm1,src/ReAgent.CodexWorkspace.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: Claude baseline test and all Codex ownership tests pass; analyzer is silent.

- [ ] **Step 8: Commit**

```powershell
git add templates/instructions templates/CLAUDE.md.template src/ReAgent.Generate.psm1 `
    src/ReAgent.CodexWorkspace.psm1 tests/ReAgent.Generate.Tests.ps1 `
    tests/ReAgent.CodexWorkspace.Tests.ps1
git commit -m "Generate shared Claude and Codex instructions"
```

---

### Task 3: Install the converted Codex skill view atomically

**Files:**

- Modify: `src/ReAgent.CodexAdapter.psm1`
- Modify: `src/ReAgent.CodexWorkspace.psm1`
- Modify: `src/ReAgent.Skills.psm1`
- Modify: `tests/ReAgent.CodexAdapter.Tests.ps1`
- Modify: `tests/ReAgent.CodexWorkspace.Tests.ps1`
- Modify: `tests/ReAgent.Skills.Tests.ps1`

**Interfaces:**

- Produces: `ConvertTo-CodexSkillText -Text <string> -NamespaceMap <hashtable> -Catalog <object> -CompatibleServers <string[]> -SkillNames <string[]>` -> converted `SKILL.md`/prose.
- Produces: `New-CodexSkillCandidate -Source <string> -Destination <string> -Pack <object> -Skill <object> -Catalog <object> -Config <object>` -> in-memory file records `{ RelativePath, Bytes }` plus marker.
- Produces: `Install-CodexSkillDirectory -Candidate <object> -SkillRoot <string> [-WhatIf]` -> `{ Name, Path, Status, Sha256, Changed }`.
- Changes: `Install-SkillPack` and `Install-AllSkill` accept `-CodexSkillRoot`; the existing reviewed-source scan/adaptation gate runs exactly once per pack before either client write.

- [ ] **Step 1: Write failing conversion and dual-view tests**

Add fixtures with `allowed-tools`, all section 6.4 constructs, one exact MCP reference, an unchanged free-prose server name, a binary script, and a reference Markdown file. Assert:

- Claude output remains byte-identical to the vendored source.
- Codex `SKILL.md` has the same `name` and no `allowed-tools`.
- Codex rewrites `mcp__mcp-windbg__list_dumps` to `mcp__mcp_windbg__list_dumps`.
- The binary/script bytes are identical.
- An SSE reference throws before either destination is changed.
- Enabled config names equal marked names in both roots.
- An unmanaged Codex skill survives install and orphan cleanup.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```powershell
$skillTestPaths = @(
    'tests/ReAgent.CodexAdapter.Tests.ps1'
    'tests/ReAgent.CodexWorkspace.Tests.ps1'
    'tests/ReAgent.Skills.Tests.ps1'
)
Invoke-Pester -Path $skillTestPaths -Output Detailed
```

Expected: FAIL because dual-view installation is not implemented.

- [ ] **Step 3: Build and validate candidates before writing**

Enumerate every source file in stable relative-path order. Treat `SKILL.md`, Markdown, text, JSON, YAML, and TOML as reviewed text; run structured Codex conversion and the existing static scan over changed text. Copy scripts and other files byte-for-byte. Add `.re-agent-managed` last with content `codex:<namespace>/<upstream>`.

Before installation, validate frontmatter name, MCP compatibility, Claude residue, and all
configured exact exceptions against the candidate records. A Codex conversion finding returns a
failed Codex pack result and leaves both clients' last complete destinations intact. A failure in
the existing shared reviewed-source gate keeps its current Claude cleanup behavior and prevents
either client write; do not expand that cleanup to Codex-only findings.

- [ ] **Step 4: Implement staged replacement and recovery**

Stage under the destination parent using a unique `.re-agent-stage-<name>-<guid>` directory. Compare a deterministic tree digest built from sorted relative paths plus SHA-256 file hashes. If unchanged, remove the stage and preserve the destination timestamp. If changed, rename a marked destination to `.re-agent-previous-<name>-<guid>`, move the complete stage into place, restore the previous directory on any exception, then remove the previous directory only after success. At function entry, recover a lone previous directory left by an interrupted earlier run before starting a new stage.

- [ ] **Step 5: Refactor the pack loop to gate once and write twice**

Keep `Test-SkillPackGate` before all writes. After it passes, call the existing Claude writer and the new Codex installer for each enabled skill. Run `Remove-OrphanedSkill` independently for `.claude\skills` and `.agents\skills`. Extend each pack result with `CodexSkillNames` and `CodexSkillRecords` without changing existing manifest fields.

- [ ] **Step 6: Run tests and analyzer**

Run:

```powershell
$skillTestPaths = @(
    'tests/ReAgent.CodexAdapter.Tests.ps1'
    'tests/ReAgent.CodexWorkspace.Tests.ps1'
    'tests/ReAgent.Skills.Tests.ps1'
)
Invoke-Pester -Path $skillTestPaths -Output Detailed
$skillModulePaths = @(
    'src/ReAgent.CodexAdapter.psm1'
    'src/ReAgent.CodexWorkspace.psm1'
    'src/ReAgent.Skills.psm1'
)
Invoke-ScriptAnalyzer -Path $skillModulePaths -Settings PSScriptAnalyzerSettings.psd1
```

Expected: all focused tests pass and analyzer emits nothing.

- [ ] **Step 7: Commit**

```powershell
git add src/ReAgent.CodexAdapter.psm1 src/ReAgent.CodexWorkspace.psm1 `
    src/ReAgent.Skills.psm1 tests/ReAgent.CodexAdapter.Tests.ps1 `
    tests/ReAgent.CodexWorkspace.Tests.ps1 tests/ReAgent.Skills.Tests.ps1
git commit -m "Install the Codex skill view"
```

---

### Task 4: Generate constrained Codex custom agents

**Files:**

- Modify: `templates/agents/static-analyst.md.template`
- Modify: `templates/agents/verifier.md.template`
- Modify: `templates/agents/dynamic-analyst.md.template`
- Modify: `src/ReAgent.Generate.psm1`
- Modify: `src/ReAgent.CodexWorkspace.psm1`
- Modify: `tests/ReAgent.Generate.Tests.ps1`
- Modify: `tests/ReAgent.CodexWorkspace.Tests.ps1`

**Interfaces:**

- Consumes: `Get-AgentToolGrant`, `New-CodexAgentServerTable`, installed `ServerResults`.
- Produces: `Get-AgentTemplateBody -Path <string>` -> body after strict frontmatter removal.
- Produces: `New-CodexAgentToml -Agent <object> -Catalog <object> -Config <object> -ServerResults <array> -TemplateRoot <string>` -> complete marked TOML.
- Produces: `Write-CodexAgentDefinition -Config <object> -Catalog <object> -ServerResults <array> -TemplateRoot <string> [-WhatIf]` -> one result per declared agent.
- Produces: `Write-CodexWorkspaceConfiguration -Config <object> -Catalog <object> -ServerResults <array> -TemplateRoot <string> [-WhatIf]` -> `{ Instruction, Agents, OmittedServers }`.

- [ ] **Step 1: Write failing custom-agent tests**

Use a fixture containing all five compatible registrations plus the three SSE entries. Assert `static-analyst.toml` and `verifier.toml`:

- Start with `# re-agent-managed: codex-custom-agent v1`.
- Parse into required `name`, `description`, `developer_instructions`, and `sandbox_mode` fields.
- Use `workspace-write` for static and `read-only` for verifier.
- Include complete transport tables for all five compatible managed servers.
- Enable only the agent's compatible targets and disable all other managed servers.
- Give static pyghidra read/write tools but no destructive tool.
- Give verifier only catalog-read tools on pyghidra and mcp-windbg.
- Contain no SSE table, bearer value, authorization header, or user token.
- Record each omitted SSE target with the exact reason.
- Do not emit disabled `dynamic-analyst`; remove only its marked prior TOML.
- Refuse an unmarked name collision.

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1,tests/ReAgent.CodexWorkspace.Tests.ps1 `
    -Output Detailed
```

Expected: FAIL because custom-agent rendering is absent.

- [ ] **Step 3: Make the specialist body client-neutral**

Replace static analyst's hard-coded `You have no Bash` paragraph with `{{CLIENT_LIMITATIONS}}`. Claude rendering substitutes the same no-Bash paragraph to preserve behavior. Codex rendering substitutes its unsupported-SSE list and explains that unavailable GUI-hosted tools normally mean the host application is closed. The verifier receives the same SSE limitations plus its existing `ai_` exclusion and no-state-mutation rule.

- [ ] **Step 4: Render fields and complete MCP tables**

Encode `description` and `developer_instructions` as TOML basic strings through `ConvertTo-CodexTomlValue`; do not use raw triple-quoted TOML. Group `Get-AgentToolGrant` results by original server and strip only the exact `mcp__<server>__` prefix to form sorted bare `enabled_tools` arrays. For every installed compatible result, emit a complete server table: targets enabled with the derived allowlist, all others disabled with an empty allowlist.

For target servers with SSE, add an omission record instead of a table. For any enabled compatible target whose auth is not `none`, throw before writing any agent file.

- [ ] **Step 5: Reconcile marked TOML files**

Use `Set-ManagedTextFile` with backups disabled. Remove disabled/removed config agents only when the existing file starts with the Codex custom-agent marker. Preserve every unrelated file under `.codex\agents`.

- [ ] **Step 6: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Generate.Tests.ps1,tests/ReAgent.CodexWorkspace.Tests.ps1 `
    -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.Generate.psm1,src/ReAgent.CodexWorkspace.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: both enabled agents pass every grant/transport assertion; analyzer is silent.

- [ ] **Step 7: Commit**

```powershell
git add templates/agents src/ReAgent.Generate.psm1 src/ReAgent.CodexWorkspace.psm1 `
    tests/ReAgent.Generate.Tests.ps1 tests/ReAgent.CodexWorkspace.Tests.ps1
git commit -m "Generate constrained Codex specialists"
```

---

### Task 5: Implement Codex workspace checks C0-C4

**Files:**

- Create: `src/ReAgent.CodexVerify.psm1`
- Create: `tests/ReAgent.CodexVerify.Tests.ps1`
- Modify: `src/ReAgent.CodexAdapter.psm1`

**Interfaces:**

- Produces: `Get-CodexInstructionCheck -Config <object> -TemplateRoot <string>` -> C0 result.
- Produces: `Get-CodexSkillSetCheck -Config <object>` -> C1 result.
- Produces: `Get-CodexSkillIdentityCheck -Config <object>` -> C2 result.
- Produces: `Get-CodexSkillMcpCheck -Config <object> -Catalog <object>` -> C3 result.
- Produces: `Get-CodexResidueCheck -Config <object>` -> C4 result.
- Each result uses `New-CheckResult` and has `Name` beginning with its stable ID.

- [ ] **Step 1: Write one pass and at least one focused failure fixture per check**

Create a complete marked workspace fixture and first assert all five checks pass. Clone that
fixture for each row so mutations cannot leak between tests:

| Check | Exact mutation | Required failure detail |
|---|---|---|
| C0 | Remove the marker, then separately append `drift` to `AGENTS.md`. | Path plus `unmanaged` or `byte mismatch`, respectively. |
| C1 | Remove one enabled Codex skill, then add one extra marked skill. | Sorted expected, Claude, and Codex name sets. |
| C2 | Change one `SKILL.md` frontmatter `name` without renaming its directory. | Directory name, declared name, and configured name. |
| C3 | Add `mcp__pdbsql__get_schema`, then add `mcp__pyghidra_mcp__not_catalogued`. | `legacy SSE is unsupported by Codex`, then `tool absent from catalog`. |
| C4 | Insert each banned construct one at a time into an active generated file. | Relative file, stable rule ID, and one-based line number. |
| C4 exception | Configure one exact `{ skill, file, ruleId, justification }`, then vary each identity field separately. | Exact match is waived; every near match still fails. |

The table-driven C4 cases are `.claude/skills`, `.claude/agents`, `CLAUDE.md wins`,
`TodoWrite`, `Task tool`, `Agent tool`, `Skill tool`, and
`mcp__server-with-hyphen__tool`. Require the pass fixture and every mutated fixture to return a
result whose `Name` begins with the corresponding stable ID.

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexVerify.Tests.ps1 -Output Detailed
```

Expected: FAIL because `ReAgent.CodexVerify.psm1` does not exist.

- [ ] **Step 3: Implement deterministic C0-C4 checks**

C0 re-renders expected instructions and compares exact bytes plus marker. C1 compares three sorted sets: enabled config names, marked Claude names, and marked Codex names. C2 parses every generated `SKILL.md`. C3 extracts exact MCP references from all active text records, reverses the namespace map, and checks transport compatibility plus catalog membership. C4 reports file, rule, and line and applies an exception only when all three configured identity fields match.

Return all findings in each check's `Detail`; never stop at the first file.

- [ ] **Step 4: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexVerify.Tests.ps1 -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.CodexVerify.psm1,src/ReAgent.CodexAdapter.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: C0-C4 fixtures pass and analyzer produces no output.

- [ ] **Step 5: Commit**

```powershell
git add src/ReAgent.CodexVerify.psm1 src/ReAgent.CodexAdapter.psm1 `
    tests/ReAgent.CodexVerify.Tests.ps1
git commit -m "Verify Codex instructions and skills"
```

---

### Task 6: Implement custom-agent and ownership checks C5-C8

**Files:**

- Modify: `src/ReAgent.CodexVerify.psm1`
- Modify: `tests/ReAgent.CodexVerify.Tests.ps1`
- Modify: `src/ReAgent.Codex.psm1`
- Modify: `tests/ReAgent.Codex.Tests.ps1`

**Interfaces:**

- Produces: `Read-CodexAgentToml -Path <string>` -> strict object for the generator's supported TOML subset; rejects duplicates, unknown fields, malformed strings/arrays, and incomplete transports.
- Produces: `Get-CodexAgentIdentityCheck -Config <object>` -> C5.
- Produces: `Get-CodexAgentGrantCheck -Config <object> -Catalog <object>` -> C6.
- Produces: `Get-CodexSecretIsolationCheck -Config <object> -ServerResults <array>` -> C7.
- Produces: `Get-CodexOwnershipCheck -Config <object> -Catalog <object> -ServerResults <array> -TemplateRoot <string> [-ReconciliationRecords <array>]` -> C8.
- Produces: `Get-CodexWorkspaceCheck -Config <object> -Catalog <object> -ServerResults <array> -TemplateRoot <string> [-ReconciliationRecords <array>]` -> ordered C0-C8 results.
- Produces: `Write-CodexVerificationReport -Config <object> -Checks <array> -Observations <array>` -> `codex-verify-report.json`.

- [ ] **Step 1: Write strict TOML and C5-C8 fixtures**

Cover quotes, apostrophes, Windows paths, Unicode, escaped newlines, and a body containing `"""`. Add failures for missing required fields, name/file/config disagreement, incomplete transport, unintended enabled server, stale/missing catalog tool, verifier write/destructive grants, literal token/header leakage, transport drift from `ServerResults`, changed marked bytes, and unmanaged artifacts incorrectly appearing in the managed set.

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexVerify.Tests.ps1,tests/ReAgent.Codex.Tests.ps1 `
    -Output Detailed
```

Expected: FAIL because C5-C8 and report serialization are absent.

- [ ] **Step 3: Implement the strict generated-subset reader**

Parse exactly the fields this generator emits: marker, scalar role fields, string arrays, `[mcp_servers.'name']`, and optional `.env` tables. Reject any server table without `url` or `command`. This deliberately reproduces the runtime gate that rejected the measured partial file; it is not a general TOML parser.

- [ ] **Step 4: Implement grant, secret, transport, and ownership checks**

C6 recomputes expected grants from config/catalog and compares exact sorted tool/server sets. C7
scans decoded scalar values as well as raw text, rejects `Authorization`, `Bearer`, configured token
values, sensitive environment keys, enabled authenticated targets, and any URL/command/args/env
drift from `ServerResults`. C8 re-renders all managed candidates and compares bytes while ignoring
unmarked siblings. When Phase 6 supplies current-run reconciliation records, C8 also fails if any
`create`, `update`, or `remove` record has `OwnedBefore = $false`; `-VerifyOnly` passes an empty
record set and performs the deterministic byte/marker checks only.

- [ ] **Step 5: Compose C0-C8 and preserve registration verification**

Keep `Get-CodexRegistrationCheck` in `ReAgent.Codex.psm1`. `Get-CodexWorkspaceCheck` returns C0 through C8 in order. `Write-CodexVerificationReport` writes:

```json
{
  "generatedAt": "2026-09-14T12:00:00.0000000-07:00",
  "codexVersion": "codex-cli 0.153.4",
  "checks": [],
  "attendedObservations": []
}
```

The timestamp is report metadata, never part of generated-artifact hashing or idempotency comparisons.

- [ ] **Step 6: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexVerify.Tests.ps1,tests/ReAgent.Codex.Tests.ps1 `
    -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.CodexVerify.psm1,src/ReAgent.Codex.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: C5-C8 and existing registration tests pass; analyzer is silent.

- [ ] **Step 7: Commit**

```powershell
git add src/ReAgent.CodexVerify.psm1 src/ReAgent.Codex.psm1 `
    tests/ReAgent.CodexVerify.Tests.ps1 tests/ReAgent.Codex.Tests.ps1
git commit -m "Verify Codex specialists and ownership"
```

---

### Task 7: Wire the combined installer and prove WhatIf/idempotency

**Files:**

- Modify: `Install-REAgent.ps1`
- Modify: `src/ReAgent.Verify.psm1`
- Modify: `tests/Integration.Tests.ps1`
- Modify: `tests/ReAgent.Verify.Tests.ps1`

**Interfaces:**

- Phase 4 sets `Context.CodexWorkspaceConfiguration` from `Write-CodexWorkspaceConfiguration` after user MCP registration.
- Phase 5 passes `.agents\skills` to `Install-AllSkill` and sets `Context.CodexSkillResults`.
- Phase 6 appends registration plus C0-C8 checks to `AdditionalChecks` and calls `Assert-VerificationPassed`.

- [ ] **Step 1: Write failing phase and mutation-boundary tests**

Extend `tests/Integration.Tests.ps1` to assert module import order includes `CodexAdapter`, `CodexWorkspace`, and `CodexVerify`; Phase 4 invokes both Claude and Codex generators; Phase 5 emits set-equal names; Phase 6 includes registration and C0-C8; and any Codex failure produces a nonzero process result.

Add complete-run fixtures proving a second run preserves bytes/timestamps, `-WhatIf` leaves both Codex roots absent, and a missing instruction, skill, or agent fails `-VerifyOnly`.

- [ ] **Step 2: Run integration tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/Integration.Tests.ps1,tests/ReAgent.Verify.Tests.ps1 `
    -Output Detailed
```

Expected: FAIL because the new modules and phase calls are not wired.

- [ ] **Step 3: Extend the shared context and phase bodies**

Add initialized context fields `CodexWorkspaceConfiguration = $null` and
`CodexSkillResults = @()`. Preserve current user MCP registration in Phase 4, then call project
generation. Make every writer and orphan reconciler return records containing `Action`, `Path`,
`OwnedBefore`, and `Changed`; Phase 6 passes their combined records to C8. Pass
`-WhatIf:$WhatIfPreference` explicitly through every new writer so conversion still runs but no
destination is created.

Under `-VerifyOnly`, replay server/skill/agent state from the manifest, render expected candidates in memory, run registration and C0-C8, then let the existing `Assert-VerificationPassed` fail the phase and process.

- [ ] **Step 4: Run focused tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/Integration.Tests.ps1,tests/ReAgent.Verify.Tests.ps1 `
    -Output Detailed
Invoke-ScriptAnalyzer -Path Install-REAgent.ps1,src/ReAgent.Verify.psm1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: phase, VerifyOnly, idempotency, and WhatIf tests pass; analyzer is silent.

- [ ] **Step 5: Commit**

```powershell
git add Install-REAgent.ps1 src/ReAgent.Verify.psm1 tests/Integration.Tests.ps1 `
    tests/ReAgent.Verify.Tests.ps1
git commit -m "Wire Codex workspace parity into the installer"
```

---

### Task 8: Add manifest records and standalone Codex parity

**Files:**

- Modify: `src/ReAgent.Manifest.psm1`
- Modify: `tests/ReAgent.Manifest.Tests.ps1`
- Modify: `install-codex.ps1`
- Modify: `tests/Integration.Tests.ps1`

**Interfaces:**

- Produces: `ConvertTo-CodexWorkspaceManifestRecord -Context <hashtable>` -> ordered `codexWorkspace` object.
- Produces: `Get-RecordedCodexWorkspaceResult -Config <object> [-ManifestName <string>]` -> replayed instruction/skill/agent records.
- Standalone `-ConfigureOnly` reconciles user registration plus all project artifacts from already-vendored repository content.
- Standalone `-VerifyOnly` changes nothing and runs registration plus C0-C8.

- [ ] **Step 1: Write failing manifest tests**

Assert the manifest contains root, instruction path/status/SHA-256, one record per enabled skill, the two enabled agent records with compatible server names/tool counts, and exact omitted SSE reasons. Assert serialized JSON contains neither a fixture token nor `Authorization`, full `config.toml`, model, reasoning, sandbox policy beyond the agent's required `sandbox_mode`, approval policy, login, memories, or plugin settings.

- [ ] **Step 2: Write failing standalone installer tests**

Mock downloads/service installation and prove `-ConfigureOnly` invokes registration, instruction, skill, and agent reconciliation without installing Claude files or services. Prove `-VerifyOnly` invokes no writer, fails for one missing artifact and one verifier write grant, and preserves unrelated user TOML plus unmanaged project artifacts.

- [ ] **Step 3: Run tests and verify failure**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Manifest.Tests.ps1,tests/Integration.Tests.ps1 `
    -Output Detailed
```

Expected: FAIL because `codexWorkspace` and standalone workspace wiring are absent.

- [ ] **Step 4: Serialize and replay Codex workspace state**

Build hashes from generated outputs, not source directories. Use compatible server names in agent records and exact SSE omission records. Make all new manifest properties optional on read so pre-parity manifests remain valid and `-VerifyOnly` reports missing artifacts rather than throwing on absent JSON properties.

- [ ] **Step 5: Wire standalone modes through the shared functions**

Import the three new modules. In `-ConfigureOnly`, reuse recorded server results, then reconcile registration and workspace artifacts from the checked-in templates/vendor tree. In `-VerifyOnly`, only read/re-render/check. Write `codex-manifest.json` after non-VerifyOnly runs with the same `codexWorkspace` shape as the combined manifest.

- [ ] **Step 6: Run tests and analyzer**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.Manifest.Tests.ps1,tests/Integration.Tests.ps1 `
    -Output Detailed
Invoke-ScriptAnalyzer -Path src/ReAgent.Manifest.psm1,install-codex.ps1 `
    -Settings PSScriptAnalyzerSettings.psd1
```

Expected: manifest and standalone tests pass; analyzer is silent.

- [ ] **Step 7: Commit**

```powershell
git add src/ReAgent.Manifest.psm1 install-codex.ps1 `
    tests/ReAgent.Manifest.Tests.ps1 tests/Integration.Tests.ps1
git commit -m "Report and reconcile Codex workspace state"
```

---

### Task 9: Update operator documentation and acceptance recording

**Files:**

- Modify: `README.md`
- Modify: `docs/mvp/CODEX.md`
- Modify: `docs/mvp/MVP.md`
- Modify: `docs/mvp/HANDOFF.md`
- Modify: `src/ReAgent.CodexVerify.psm1`
- Modify: `tests/ReAgent.CodexVerify.Tests.ps1`

**Interfaces:**

- Produces: `New-CodexAcceptanceObservation -Id <string> -Status <pass|fail> -Evidence <string>` for IDs L0-L5.
- `Write-CodexVerificationReport` requires all L0-L5 observations when called for an attended acceptance record.

- [ ] **Step 1: Add failing acceptance-record tests**

Require exactly these observation IDs and reject duplicates, missing evidence, unknown IDs, or a pass with empty evidence:

```text
L0 instruction source
L1 eleven skills
L2 two custom agents
L3 verifier tool boundary
L4 specialist read-only MCP call
L5 optional GUI host startup
```

- [ ] **Step 2: Implement validated observation records**

Return `{ Id, Status, Evidence, ObservedAt }`. Keep observations separate from deterministic C0-C8 results. Do not inspect model prose to manufacture a pass.

- [ ] **Step 3: Update documentation with exact commands and limitations**

Document:

```powershell
codex --strict-config -C C:\re\agent
```

State that the operator must trust the project so Codex loads project `.codex` layers, `/skills` must list the eleven expected names, the agent picker must show `static-analyst` and `verifier`, and SSE servers remain Claude-only. Explain the measured full-transport custom-agent requirement and that project agent files contain local endpoints/commands but never credentials.

Add the L0-L5 attended checklist and the exact evidence expected for each result. Update the measured test/analyzer counts only after Task 10.

- [ ] **Step 4: Run focused tests and documentation checks**

Run:

```powershell
Invoke-Pester -Path tests/ReAgent.CodexVerify.Tests.ps1,tests/Integration.Tests.ps1 `
    -Output Detailed
rg -n "AGENTS.md|\.agents/skills|\.codex/agents|legacy SSE|strict-config|L0|L5" `
    README.md docs/mvp/CODEX.md docs/mvp/MVP.md docs/mvp/HANDOFF.md
```

Expected: tests pass and every required operator concept appears in the documentation.

- [ ] **Step 5: Commit**

```powershell
git add README.md docs/mvp/CODEX.md docs/mvp/MVP.md docs/mvp/HANDOFF.md `
    src/ReAgent.CodexVerify.psm1 tests/ReAgent.CodexVerify.Tests.ps1
git commit -m "Document Codex workspace parity acceptance"
```

---

### Task 10: Run full static, integration, and attended acceptance

**Files:**

- Modify after measurement: `docs/mvp/MVP.md`
- Modify after measurement: `docs/mvp/HANDOFF.md`
- Generated outside the repository: `<Config.paths.stateRoot>\codex-verify-report.json`

**Interfaces:**

- Consumes every prior task.
- Produces measured suite/analyzer results plus L0-L5 attended evidence.

- [ ] **Step 1: Run the complete automated suite**

Run:

```powershell
Import-Module Pester -MinimumVersion 5.5.0
$result = Invoke-Pester -Path tests -Output Detailed -PassThru
$result | Select-Object TotalCount,PassedCount,FailedCount,SkippedCount
```

Expected: `FailedCount = 0`. Record the actual total and passed counts; do not retain an old count from HANDOFF.

- [ ] **Step 2: Run whole-repository static analysis**

Run:

```powershell
$findings = @(Invoke-ScriptAnalyzer -Path . -Recurse `
    -Settings PSScriptAnalyzerSettings.psd1)
$findings | Format-Table -AutoSize
if ($findings.Count -ne 0) { throw "$($findings.Count) analyzer finding(s)." }
```

Expected: no findings.

- [ ] **Step 3: Run disposable-root idempotency and WhatIf checks**

Use the integration fixture, not the real installer, to run two complete reconciliations. Hash every managed Codex file after each run and compare `LastWriteTimeUtc`; assert exact equality. Run the same fixture with `-WhatIf` against absent roots and assert neither `.agents` nor `.codex` nor `AGENTS.md` exists afterward.

- [ ] **Step 4: Run real VerifyOnly before attended applications**

Run from an unelevated analyst shell:

```powershell
.\Install-REAgent.ps1 -VerifyOnly
```

Expected: registration plus C0-C8 pass, GUI probes may be `not-testable`, and the process exits 0. This command is read-only; if artifacts are not installed yet, first run the elevated install in Step 5.

- [ ] **Step 5: Run the real elevated install twice**

Run once only after reviewing the pending diff and confirming `C:\re\agent` is the configured root:

```powershell
.\Install-REAgent.ps1
.\Install-REAgent.ps1
```

Expected: the first run creates/reconciles Codex artifacts; the second reports them unchanged, creates no new backup, and preserves unmanaged files.

- [ ] **Step 6: Perform attended Codex acceptance**

Open Binary Ninja and run **Plugins > MCP > Start Server**. Open x64dbg with an x64 target; leave x32dbg closed. Start:

```powershell
codex --strict-config -C C:\re\agent
```

Record direct observations:

1. L0: Codex names `AGENTS.md` among loaded instructions.
2. L1: `/skills` lists exactly the eleven spec names.
3. L2: `static-analyst` and `verifier` are available; `dynamic-analyst` is absent.
4. L3: verifier cannot see pyghidra write/destructive tools.
5. L4: one specialist successfully calls `list_project_binaries`, `decompile_function`, `list_dumps`, or another catalog-read tool.
6. L5: startup succeeds while x32dbg is closed.

Pass those six evidence strings through `New-CodexAcceptanceObservation`, then call `Write-CodexVerificationReport` with the current C0-C8 checks and observations. Any failed observation leaves attended acceptance failed but does not rewrite deterministic check results.

- [ ] **Step 7: Run attended installer verification**

Run:

```powershell
.\Install-REAgent.ps1 -VerifyOnly -Attended
```

Expected: C0-C8 remain pass; open-host direct probes pass; closed optional hosts do not cause Codex startup failure.

- [ ] **Step 8: Record measured evidence and commit**

Update `docs/mvp/MVP.md` and `docs/mvp/HANDOFF.md` with the actual Codex version, Pester counts, analyzer result, idempotency result, and L0-L5 outcome.

```powershell
git add docs/mvp/MVP.md docs/mvp/HANDOFF.md
git commit -m "Record Codex parity acceptance results"
```

---

## Spec Coverage Review

- Sections 5 and 8.1 instruction generation: Tasks 2 and 7.
- Section 6 skill conversion, set equality, scripts/references, and ownership: Tasks 1, 3, and 5.
- Section 7 custom-agent schema, complete measured transports, grants, omission, and cleanup: Tasks 1, 4, and 6.
- Sections 8.2-8.3 standalone modes and WhatIf: Tasks 7 and 8.
- Section 9 C0-C8 and attended acceptance: Tasks 5, 6, 9, and 10.
- Section 10 manifest: Task 8.
- Sections 11-12 security, ownership, migration, recovery, and idempotency: Tasks 2-4, 6-8, and 10.
- Section 13 unit, integration, static-analysis, and live requirements: Tasks 1-10, with final evidence in Task 10.

No plan step enables legacy SSE, duplicates a credential, changes analyst model/reasoning/approval policy, enables `dynamic-analyst`, adds hooks, or packages a plugin.
