# Install-REAgent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Install-REAgent.ps1`, a PowerShell installer that runs on an existing FLARE VM and leaves Claude Code able to drive x64dbg, Ghidra, Binary Ninja, and WinDbg through MCP.

**Architecture:** A thin entry-point script over a set of PowerShell modules, split so that *decision logic is pure and unit-testable* and *side effects are thin and mockable*. Config parsing, port allocation, JSON generation, version comparison, and JSON merging are pure functions tested with Pester on any machine. Discovery, download, and install functions are thin wrappers mocked in tests and exercised for real only on the FLARE host. A declarative phase table drives a generic runner.

**Tech Stack:** PowerShell 5.1, Pester 5.5+ (test framework), PSScriptAnalyzer (lint), Python 3.10+ venvs for two of the servers.

**Spec:** `docs/mvp/MVP_SPEC.md` — read it alongside this plan. Scope and locked decisions are in `docs/mvp/MVP.md`.

## Global Constraints

Copied verbatim from the spec and `~/AGENTS.md`. Every task's requirements implicitly include this section.

- **Target runtime: PowerShell 5.1.** No PowerShell 7-only syntax (no `??`, no `?:`, no `-Parallel`).
- **Python 3.10 or later** for venv-based servers. **Node.js is not required by anything in this build — do not install it.**
- **All MCP servers bind `127.0.0.1`. Never `0.0.0.0`.**
- **Every HTTP-transport server requires a bearer token.** Generate with `System.Security.Cryptography.RandomNumberGenerator`, except x64dbg, whose token is owned by the tool and must be read back.
- **Do not use DPAPI** for token storage — blobs are machine- and user-bound.
- **Pin and hash-verify every downloaded source.** Exception: `gui-builtin-http` has no source.
- **Never delete anything the script did not create in this run.** Sole exception: generated config files.
- **Idempotency is mandatory.** A second run changes nothing and reports so.
- Function limits: **≤100 lines, cyclomatic complexity ≤8, ≤5 positional params, 100-char lines.**
- **Zero warnings** from PSScriptAnalyzer. Unfixable warnings get an inline suppression with a justification comment.
- Comment-based help on every exported function.
- Commits: imperative mood, ≤72-char subject, one logical change. **Never add Co-Authored-By or any AI attribution.**

## Deviation from the spec's build order — read this first

`docs/mvp/MVP.md` lists x64dbg as the first server to build end-to-end. **This plan does pyghidra-mcp first instead**, for one reason: x64dbg requires an attended GUI to verify, so its "end-to-end" milestone cannot be proven by an automated test. pyghidra-mcp is unattended, so Task 9 can close the full chain — config → install → generate → connect → live tool call — inside a Pester run. x64dbg still comes before the remaining servers, at Task 11.

The milestone intent is unchanged: prove the whole chain on one server before scaling out. Only the choice of *which* server moves.

## Open items resolved by this plan

✅ **All of O1–O7 are now resolved up front**, by measurement on the host and against upstream sources,
before any code is written. `docs/mvp/MVP_FINDINGS.md` carries the evidence; `MVP_SPEC.md` §13 carries
the summary. The tasks below consume the answers instead of re-deriving them.

| # | Resolution |
|---|---|
| O1 | `disabledMcpjsonServers` is correct. **Also emit `enableAllProjectMcpServers: true`** — and note that `.mcp.json` servers stay ⏸ Pending until `claude` is run interactively once in the project directory and the trust prompt accepted. Without that, `claude mcp list` shows nothing connected no matter what the settings say. |
| O2 | **Prebuilt — no Zig.** `duty1g/x64dbg-mcp-server` **v1.3** ships `x64dbg-MCP-Server-v1.3.zip` containing a `dist/` tree that deploys x32 and x64 in one copy. Drop Zig from Task 7 entirely. |
| O3 | **`%APPDATA%\Binary Ninja\settings.json`**, confirmed present and currently `{}`. `%LOCALAPPDATA%\Vector35` does not exist — drop it as a candidate. Merge with backup, as Task 8 already does. |
| O4 | **Test binary is `C:\Windows\System32\winver.exe`.** Present on every Windows install, non-malicious, no external download. Assertions are *non-empty function list* and *a decompiled `entry`* — both deterministic without pinning an exact count across Windows versions. ✅ Verified: Ghidra finds `entry` at `0x1400013c0`. |
| O5 | **Pre-seed.** The plugin reads and preserves an existing `mcp_config.json`; the token is generated only when missing. Fields are `IpAddress` / `Port` / `AutoStart` / **`AuthToken`** — note the casing, Task 8's reader must match it. Token format is **32** hex chars, not 64. |
| O6 | **Binary Ninja does NOT autostart its server.** `Plugins > MCP > Start Server`, every session. Goes in `CLAUDE.md` and the tier-2 prompt. |
| O7 | No documented minimum version. **Gate on capability**: probe `binaryninja.exe` for the literal `ui.mcp.enabled`. This host's 6.0.10601.0 has it. |

**Three architectural consequences the tasks below already reflect:**

1. **pyghidra-mcp runs over streamable-http, not stdio** — stdio breaks its symbol loading. It needs a
   new `venv-http` kind and a logon Scheduled Task, and it has **no auth mechanism at all**.
2. **x64dbg is two servers**, on 9094 (x64) and 9095 (x32), each with its own config file.
3. **Nothing needs installing on this host.** `Get-MissingPrereqs` must return empty here; if it does
   not, the discovery logic is wrong rather than the host.

---

## File Structure

```
Install-REAgent.ps1                    # entry point: param block, module imports, phase dispatch
re-agent.config.json                   # the single source of truth for pins, ports, paths
templates/
  CLAUDE.md.template                   # operating contract, copied verbatim
src/
  ReAgent.Common.psm1                  # logging, phase result objects, Invoke-Phase, exit codes
  ReAgent.Config.psm1                  # config load, schema validation, port map, ports.json
  ReAgent.Discovery.psm1               # host inventory, preflight hard blockers
  ReAgent.Prereqs.psm1                 # Python / JDK / cdb.exe / uv install-if-missing
  ReAgent.Symbols.psm1                 # _NT_SYMBOL_PATH + symchk pre-warm
  ReAgent.Tokens.psm1                  # bearer generation, x64dbg read-back, token storage
  ReAgent.Json.psm1                    # safe JSON merge with backup (used by Binary Ninja)
  ReAgent.Servers.psm1                 # dispatcher + one handler per `kind`
  ReAgent.Generate.psm1                # .mcp.json, .claude/settings.json, CLAUDE.md
  ReAgent.Verify.psm1                  # tier 1 and tier 2 checks
  ReAgent.Manifest.psm1                # manifest.json assembly
tests/
  ReAgent.Common.Tests.ps1
  ReAgent.Config.Tests.ps1
  ReAgent.Discovery.Tests.ps1
  ReAgent.Prereqs.Tests.ps1
  ReAgent.Symbols.Tests.ps1
  ReAgent.Tokens.Tests.ps1
  ReAgent.Json.Tests.ps1
  ReAgent.Servers.Tests.ps1
  ReAgent.Generate.Tests.ps1
  ReAgent.Verify.Tests.ps1
  ReAgent.Manifest.Tests.ps1
  Integration.Tests.ps1                # end-to-end idempotency, runs on the FLARE host only
```

**Why this split:** the four boundaries that matter are *data* (Config), *observation* (Discovery), *mutation* (Prereqs/Symbols/Servers), and *emission* (Generate/Manifest). Verify reads across all of them and writes nothing. Tokens and Json are separated because both are pure, security-sensitive, and used by more than one server handler — exactly the kind of logic that must be unit-tested in isolation rather than buried inside an install path.

---

## Task 1: Repository scaffold and test harness

**Files:**
- Create: `Install-REAgent.ps1` (stub), `src/ReAgent.Common.psm1`, `tests/ReAgent.Common.Tests.ps1`
- Create: `.gitignore`, `PSScriptAnalyzerSettings.psd1`

**Interfaces:**
- Consumes: nothing
- Produces: `Write-ReAgentLog -Level <string> -Message <string>`; `New-PhaseResult -Id <int> -Name <string> -Status <string> -DurationMs <int> -ErrorMessage <string>` returning a PSCustomObject with those properties; `Get-ReAgentExitCode -PhaseResults <array>` returning `0`/`1`/`2`.

- [ ] **Step 1: Install the test toolchain**

PowerShell 5.1 ships Pester 3.x, whose syntax is incompatible with what this plan uses. Install Pester 5 explicitly:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.5.0
Get-Module Pester | Select-Object Version
```

Expected: version 5.5.0 or higher.

- [ ] **Step 2: Create the analyzer settings**

Create `PSScriptAnalyzerSettings.psd1`:

```powershell
@{
    Severity = @('Error', 'Warning')
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
```

- [ ] **Step 3: Write the failing test**

Create `tests/ReAgent.Common.Tests.ps1`:

```powershell
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
        { New-PhaseResult -Id 1 -Name 'X' -Status 'banana' -DurationMs 0 } |
            Should -Throw
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
```

- [ ] **Step 4: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Common.Tests.ps1 -Output Detailed`
Expected: FAIL — the module file does not exist, so `Import-Module` errors.

- [ ] **Step 5: Write the minimal implementation**

Create `src/ReAgent.Common.psm1`:

```powershell
Set-StrictMode -Version Latest

$Script:ValidPhaseStatus = @('ok', 'skipped', 'failed', 'aborted')

function Write-ReAgentLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host and the transcript.
    .PARAMETER Level
        One of INFO, WARN, ERROR.
    .PARAMETER Message
        The text to log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $stamp = (Get-Date).ToString('o')
    Write-Host "[$stamp] [$Level] $Message"
}

function New-PhaseResult {
    <#
    .SYNOPSIS
        Builds the result record for a single phase.
    .PARAMETER Status
        One of ok, skipped, failed, aborted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$DurationMs,
        [string]$ErrorMessage = ''
    )
    if ($Script:ValidPhaseStatus -notcontains $Status) {
        throw "Invalid phase status '$Status'. Expected one of: $($Script:ValidPhaseStatus -join ', ')"
    }
    [PSCustomObject]@{
        Id           = $Id
        Name         = $Name
        Status       = $Status
        DurationMs   = $DurationMs
        ErrorMessage = $ErrorMessage
    }
}

function Get-ReAgentExitCode {
    <#
    .SYNOPSIS
        Maps a set of phase results to the script's process exit code.
    .DESCRIPTION
        0 = all good, 1 = completed with non-fatal failures, 2 = aborted on a hard blocker.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$PhaseResults)

    if ($PhaseResults | Where-Object { $_.Status -eq 'aborted' }) { return 2 }
    if ($PhaseResults | Where-Object { $_.Status -eq 'failed' })  { return 1 }
    return 0
}

Export-ModuleMember -Function Write-ReAgentLog, New-PhaseResult, Get-ReAgentExitCode
```

- [ ] **Step 6: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Common.Tests.ps1 -Output Detailed`
Expected: PASS, 5 tests.

- [ ] **Step 7: Run the linter**

Run: `Invoke-ScriptAnalyzer -Path src/ -Settings PSScriptAnalyzerSettings.psd1 -Recurse`
Expected: no output (zero findings). Fix anything reported before continuing.

- [ ] **Step 8: Commit**

```bash
git add Install-REAgent.ps1 src/ReAgent.Common.psm1 tests/ReAgent.Common.Tests.ps1 PSScriptAnalyzerSettings.psd1 .gitignore
git commit -m "Add project scaffold, logging, and phase result types"
```

---

## Task 2: Config module — load, validate, allocate ports

**Files:**
- Create: `src/ReAgent.Config.psm1`, `tests/ReAgent.Config.Tests.ps1`, `re-agent.config.json`

**Interfaces:**
- Consumes: `Write-ReAgentLog` from Task 1.
- Produces: `Get-ReAgentConfig -Path <string>` returning a PSCustomObject; `Test-ReAgentConfigSchema -Config <object>` returning `$true` or throwing; `Get-ServerPortMap -Config <object>` returning a hashtable of server name → int port; `Write-PortsJson -PortMap <hashtable> -Path <string>`.

- [ ] **Step 1: Write the failing test**

Create `tests/ReAgent.Config.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Config.psm1" -Force

    $Script:GoodConfig = [PSCustomObject]@{
        version = 1
        paths   = [PSCustomObject]@{
            toolRoot = 'C:\re'; agentRoot = 'C:\re\agent'
            stateRoot = 'C:\ProgramData\re-lab'; symbolCache = 'C:\re\symbols'
        }
        mcpServers = @(
            [PSCustomObject]@{ name='x64dbg-x64';   enabled=$true;  kind='plugin-inproc';
                               transport='http';  bind='127.0.0.1'; port=9094 },
            [PSCustomObject]@{ name='binaryninja';  enabled=$true;  kind='gui-builtin-http';
                               transport='http';  bind='127.0.0.1'; port=24642 },
            [PSCustomObject]@{ name='pyghidra-mcp'; enabled=$true;  kind='venv-stdio';
                               transport='stdio'; bind='127.0.0.1'; port=0 }
        )
    }
}

Describe 'Test-ReAgentConfigSchema' {
    It 'accepts a well-formed config' {
        Test-ReAgentConfigSchema -Config $Script:GoodConfig | Should -BeTrue
    }

    It 'rejects a server bound to 0.0.0.0' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[0].bind = '0.0.0.0'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*0.0.0.0*'
    }

    It 'rejects an unknown kind' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[0].kind = 'magic'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*magic*'
    }

    It 'rejects duplicate ports across HTTP servers' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[1].port = 9094
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*9094*'
    }

    It 'rejects duplicate server names' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[1].name = 'x64dbg-x64'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*x64dbg-x64*'
    }
}

Describe 'Get-ServerPortMap' {
    It 'includes only servers that actually use a port' {
        # pyghidra-mcp is transport=stdio in this fixture only; the shipped config
        # uses venv-http. The rule under test is 'stdio has no port', not the pin.
        $map = Get-ServerPortMap -Config $Script:GoodConfig
        $map['x64dbg-x64'] | Should -Be 9094
        $map['binaryninja'] | Should -Be 24642
        $map.ContainsKey('pyghidra-mcp') | Should -BeFalse
    }
}

Describe 'Write-PortsJson' {
    It 'round-trips the port map through disk' {
        $tmp = Join-Path $TestDrive 'ports.json'
        Write-PortsJson -PortMap @{ 'x64dbg-x64' = 9094 } -Path $tmp
        (Get-Content $tmp -Raw | ConvertFrom-Json).'x64dbg-x64' | Should -Be 9094
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the minimal implementation**

Create `src/ReAgent.Config.psm1`:

```powershell
Set-StrictMode -Version Latest

$Script:ValidKinds = @('plugin-inproc', 'venv-stdio', 'venv-http',
                       'gui-builtin-http', 'gui-plugin-http')

function Get-ReAgentConfig {
    <#
    .SYNOPSIS
        Loads and validates the installer configuration file.
    .PARAMETER Path
        Path to re-agent.config.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found at '$Path'. Copy re-agent.config.json next to the script or pass -ConfigPath."
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $null = Test-ReAgentConfigSchema -Config $config
    return $config
}

function Test-ReAgentConfigSchema {
    <#
    .SYNOPSIS
        Validates config structure and the invariants the installer depends on.
    .DESCRIPTION
        Throws a specific, actionable error on the first violation found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    foreach ($key in @('version', 'paths', 'mcpServers')) {
        if (-not $Config.PSObject.Properties.Name.Contains($key)) {
            throw "Config is missing the required top-level key '$key'."
        }
    }

    $seenNames = @{}
    $seenPorts = @{}
    foreach ($s in $Config.mcpServers) {
        if ($Script:ValidKinds -notcontains $s.kind) {
            throw "Server '$($s.name)' has unknown kind '$($s.kind)'. Valid kinds: $($Script:ValidKinds -join ', ')"
        }
        if ($s.bind -ne '127.0.0.1') {
            throw "Server '$($s.name)' binds '$($s.bind)'. Only 127.0.0.1 is permitted; 0.0.0.0 would expose the debugger."
        }
        if ($seenNames.ContainsKey($s.name)) {
            throw "Duplicate server name '$($s.name)' in config."
        }
        $seenNames[$s.name] = $true

        if ($s.transport -ne 'stdio') {
            if ($seenPorts.ContainsKey($s.port)) {
                throw "Port $($s.port) is assigned to both '$($seenPorts[$s.port])' and '$($s.name)'."
            }
            $seenPorts[$s.port] = $s.name
        }
    }
    return $true
}

function Get-ServerPortMap {
    <#
    .SYNOPSIS
        Builds the authoritative server-name to port mapping.
    .DESCRIPTION
        stdio servers have no port and are omitted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $map = @{}
    foreach ($s in $Config.mcpServers) {
        if ($s.transport -ne 'stdio') { $map[$s.name] = [int]$s.port }
    }
    return $map
}

function Write-PortsJson {
    <#
    .SYNOPSIS
        Emits ports.json, the single source of truth for allocated ports.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$PortMap,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $PortMap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

Export-ModuleMember -Function Get-ReAgentConfig, Test-ReAgentConfigSchema, `
    Get-ServerPortMap, Write-PortsJson
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed`
Expected: PASS, 7 tests.

- [ ] **Step 5: Create the real config file**

Create `re-agent.config.json`. Pins come from `MVP_FINDINGS.md` §5 and are real — only the asset
hashes are left as `PIN-ME`, because they are computed from the download during Task 11. Binary Ninja
has no `source` block by design.

```json
{
  "version": 1,
  "paths": {
    "toolRoot": "C:\\re",
    "agentRoot": "C:\\re\\agent",
    "stateRoot": "C:\\ProgramData\\re-lab",
    "symbolCache": "C:\\re\\symbols"
  },
  "symbols": {
    "enabled": true,
    "server": "https://msdl.microsoft.com/download/symbols",
    "prewarm": ["ntdll.dll", "kernel32.dll", "kernelbase.dll", "ws2_32.dll",
                "advapi32.dll", "ole32.dll", "crypt32.dll", "wininet.dll"]
  },
  "testBinary": "C:\\Windows\\System32\\winver.exe",
  "mcpServers": [
    {
      "name": "x64dbg-x64", "enabled": true, "kind": "plugin-inproc", "arch": "x64",
      "source": { "type": "github-release", "repo": "duty1g/x64dbg-mcp-server",
                  "pin": "v1.3", "sha256": { "x64dbg-MCP-Server-v1.3.zip": "PIN-ME" } },
      "transport": "http", "bind": "127.0.0.1", "port": 9094, "path": "/",
      "auth": "bearer-preseeded", "tokenHexChars": 32,
      "requiresHostApp": true, "verifyTier": "attended"
    },
    {
      "name": "x64dbg-x32", "enabled": true, "kind": "plugin-inproc", "arch": "x32",
      "source": { "type": "github-release", "repo": "duty1g/x64dbg-mcp-server",
                  "pin": "v1.3", "sha256": { "x64dbg-MCP-Server-v1.3.zip": "PIN-ME" } },
      "transport": "http", "bind": "127.0.0.1", "port": 9095, "path": "/",
      "auth": "bearer-preseeded", "tokenHexChars": 32,
      "requiresHostApp": true, "verifyTier": "attended"
    },
    {
      "name": "binaryninja", "enabled": true, "kind": "gui-builtin-http",
      "transport": "http", "bind": "127.0.0.1", "port": 24642, "path": "/mcp",
      "auth": "bearer-generated", "requiresHostApp": true, "verifyTier": "attended",
      "capabilityProbe": "ui.mcp.enabled",
      "perSessionStart": "Plugins > MCP > Start Server"
    },
    {
      "name": "pyghidra-mcp", "enabled": true, "kind": "venv-http",
      "source": { "type": "pypi", "package": "pyghidra-mcp", "pin": "0.2.5" },
      "transport": "http", "bind": "127.0.0.1", "port": 8762, "path": "/mcp",
      "auth": "none",
      "authExemptReason": "upstream exposes no auth mechanism; loopback-only, Profile A",
      "scheduledTask": "ReLab-pyghidra-mcp",
      "requiresHostApp": false, "verifyTier": "unattended"
    },
    {
      "name": "mcp-windbg", "enabled": true, "kind": "venv-stdio",
      "source": { "type": "pypi", "package": "mcp-windbg", "pin": "1.2.1" },
      "transport": "stdio", "bind": "127.0.0.1", "port": 0,
      "auth": "none", "requiresHostApp": false, "verifyTier": "unattended"
    },
    {
      "name": "ghidramcp", "enabled": false, "kind": "gui-plugin-http",
      "source": { "type": "github-release", "repo": "LaurieWired/GhidraMCP",
                  "pin": "1.4", "sha256": { "GhidraMCP-release-1-4.zip": "PIN-ME" } },
      "transport": "sse", "bind": "127.0.0.1", "port": 8761, "path": "/sse",
      "auth": "bearer-generated", "requiresHostApp": true, "verifyTier": "none",
      "maxGhidraVersion": "11.3.2"
    }
  ]
}
```

Three things in here are load-bearing and easy to "tidy" into breakage:

- **`"path": "/"` for both x64dbg servers.** The plugin serves streamable HTTP at the root, not
  `/mcp`. `/sse` is the legacy SSE endpoint.
- **`tokenHexChars: 32`.** x64dbg's own tokens are 16 bytes. Pre-seeding 64 hex chars may work, but
  matching the plugin's format removes the question.
- **`maxGhidraVersion` on ghidramcp.** Release 1.4 targets Ghidra 11.3.2 and this host runs 12.1.2,
  so Task 12 must record `not-installed` rather than fail.

⚠️ **VERIFY during Task 9:** pyghidra-mcp's HTTP endpoint path. FastMCP mounts streamable-http at
`/mcp` by default, but confirm against the running server before trusting `"path": "/mcp"` — a wrong
path fails at first connect, not at install.

- [ ] **Step 6: Add a test that the real config validates**

Append to `tests/ReAgent.Config.Tests.ps1`:

```powershell
Describe 'the shipped re-agent.config.json' {
    It 'passes schema validation' {
        $path = Join-Path $PSScriptRoot '..' 're-agent.config.json'
        { Get-ReAgentConfig -Path $path } | Should -Not -Throw
    }

    It 'keeps every enabled HTTP server on loopback' {
        $cfg = Get-ReAgentConfig -Path (Join-Path $PSScriptRoot '..' 're-agent.config.json')
        foreach ($s in $cfg.mcpServers) { $s.bind | Should -Be '127.0.0.1' }
    }
}
```

- [ ] **Step 7: Run all tests and the linter**

Run: `Invoke-Pester -Path tests/ -Output Detailed` then
`Invoke-ScriptAnalyzer -Path src/ -Settings PSScriptAnalyzerSettings.psd1 -Recurse`
Expected: all tests PASS, zero analyzer findings.

- [ ] **Step 8: Commit**

```bash
git add src/ReAgent.Config.psm1 tests/ReAgent.Config.Tests.ps1 re-agent.config.json
git commit -m "Add config loading, schema validation, and port allocation"
```

---

## Task 3: Discovery module — host inventory

**Files:**
- Create: `src/ReAgent.Discovery.psm1`, `tests/ReAgent.Discovery.Tests.ps1`

**Interfaces:**
- Consumes: `Write-ReAgentLog` from Task 1.
- Produces: `Find-Executable -Name <string>` returning a path string or `$null`; `Get-PythonVersion -PythonPath <string>` returning a `[version]` or `$null`; `Compare-VersionAtLeast -Actual <version> -Minimum <version>` returning a bool; `Get-HostInventory` returning a PSCustomObject with properties `Python`, `PythonVersion`, `Jdk`, `JdkVersion`, `Cdb`, `X64dbgRoot`, `GhidraRoot`, `GhidraVersion`, `BinaryNinjaRoot`, `BinaryNinjaSettingsPath`, `BinaryNinjaVersion`, `ClaudeCode`, `FreeDiskGb`, `TotalRamGb`, `IsVirtualMachine`, `IsAdministrator`.

- [ ] **Step 1: Write the failing test**

Create `tests/ReAgent.Discovery.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
}

Describe 'Compare-VersionAtLeast' {
    It 'accepts an equal version' {
        Compare-VersionAtLeast -Actual ([version]'3.10.0') -Minimum ([version]'3.10.0') |
            Should -BeTrue
    }
    It 'accepts a newer version' {
        Compare-VersionAtLeast -Actual ([version]'3.12.1') -Minimum ([version]'3.10.0') |
            Should -BeTrue
    }
    It 'rejects an older version' {
        Compare-VersionAtLeast -Actual ([version]'3.9.7') -Minimum ([version]'3.10.0') |
            Should -BeFalse
    }
    It 'rejects a null actual version' {
        Compare-VersionAtLeast -Actual $null -Minimum ([version]'3.10.0') | Should -BeFalse
    }
}

Describe 'Get-PythonVersion' {
    It 'parses the standard python --version banner' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { 'Python 3.11.4' }
        Get-PythonVersion -PythonPath 'python.exe' | Should -Be ([version]'3.11.4')
    }
    It 'returns null when the interpreter cannot be run' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { throw 'not found' }
        Get-PythonVersion -PythonPath 'nope.exe' | Should -BeNullOrEmpty
    }
}

Describe 'Find-Executable' {
    It 'returns the first path when the command resolves' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { "C:\Python\python.exe" }
        Find-Executable -Name 'python' | Should -Be 'C:\Python\python.exe'
    }
    It 'returns null when the command does not resolve' {
        Mock -ModuleName ReAgent.Discovery Invoke-CommandLine { throw 'not found' }
        Find-Executable -Name 'nosuchtool' | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the minimal implementation**

Create `src/ReAgent.Discovery.psm1`. `Invoke-CommandLine` exists solely as a seam so the tests above can mock every external call:

```powershell
Set-StrictMode -Version Latest

function Invoke-CommandLine {
    <#
    .SYNOPSIS
        Runs an external command and returns its stdout lines. Exists as a mock seam.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    & $FilePath @Arguments 2>&1
}

function Find-Executable {
    <#
    .SYNOPSIS
        Resolves an executable on PATH, returning its full path or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $out = Invoke-CommandLine -FilePath 'where.exe' -Arguments @($Name)
        $first = @($out) | Where-Object { $_ -and $_ -notmatch '^INFO:' } | Select-Object -First 1
        if ($first) { return ([string]$first).Trim() }
        return $null
    } catch {
        return $null
    }
}

function Compare-VersionAtLeast {
    <#
    .SYNOPSIS
        Returns true when Actual is present and at least Minimum.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][version]$Actual,
        [Parameter(Mandatory)][version]$Minimum
    )
    if ($null -eq $Actual) { return $false }
    return ($Actual -ge $Minimum)
}

function Get-PythonVersion {
    <#
    .SYNOPSIS
        Returns the version of a Python interpreter, or $null if it cannot be determined.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PythonPath)

    try {
        $out = Invoke-CommandLine -FilePath $PythonPath -Arguments @('--version')
        $text = (@($out) -join ' ')
        if ($text -match 'Python\s+(\d+\.\d+(\.\d+)?)') {
            return [version]$Matches[1]
        }
        return $null
    } catch {
        return $null
    }
}

Export-ModuleMember -Function Invoke-CommandLine, Find-Executable, `
    Compare-VersionAtLeast, Get-PythonVersion
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Discovery.psm1 tests/ReAgent.Discovery.Tests.ps1
git commit -m "Add executable and version discovery primitives"
```

---

## Task 4: Tool discovery and the full inventory

**Files:**
- Modify: `src/ReAgent.Discovery.psm1`
- Modify: `tests/ReAgent.Discovery.Tests.ps1`

**Interfaces:**
- Consumes: `Find-Executable`, `Get-PythonVersion`, `Invoke-CommandLine` from Task 3.
- Produces: `Find-X64dbgRoot`, `Find-GhidraRoot`, `Find-BinaryNinjaRoot` — each returning a path or `$null`; `Get-BinaryNinjaSettingsPath` returning a path string; `Get-HostInventory` returning the full inventory object described in Task 3.

- [ ] **Step 1: O3 is already resolved — confirm, do not re-derive**

`MVP_FINDINGS.md` settled this: Binary Ninja's settings file is
`%APPDATA%\Binary Ninja\settings.json`. It **exists** on this host and currently contains `{}`.
`%LOCALAPPDATA%\Vector35` does **not** exist and has been dropped as a candidate.

One command to confirm nothing has changed since:

```powershell
Get-Content "$env:APPDATA\Binary Ninja\settings.json" -Raw
```

A missing file is still legal — it is normal on a fresh install, and the merge in Task 10 must create
it. An **empty or unparseable** file is not: `Merge-JsonFile` refuses to write over what it cannot
parse, by design.

- [ ] **Step 2: Write the failing test**

Append to `tests/ReAgent.Discovery.Tests.ps1`:

```powershell
Describe 'Find-X64dbgRoot' {
    It 'prefers the PATH-resolved location and returns its release root' {
        Mock -ModuleName ReAgent.Discovery Find-Executable {
            'C:\Tools\x64dbg\release\x64\x64dbg.exe'
        }
        Find-X64dbgRoot | Should -Be 'C:\Tools\x64dbg\release'
    }

    It 'falls back to well-known locations when PATH misses' {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Test-Path {
            $LiteralPath -eq 'C:\Tools\x64dbg\release\x64\x64dbg.exe'
        } -ParameterFilter { $LiteralPath }
        Find-X64dbgRoot | Should -Be 'C:\Tools\x64dbg\release'
    }

    It 'returns null when x64dbg is absent' {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Test-Path { $false }
        Find-X64dbgRoot | Should -BeNullOrEmpty
    }
}

Describe 'Get-HostInventory' {
    BeforeEach {
        Mock -ModuleName ReAgent.Discovery Find-Executable { $null }
        Mock -ModuleName ReAgent.Discovery Find-X64dbgRoot { $null }
        Mock -ModuleName ReAgent.Discovery Find-GhidraRoot { $null }
        Mock -ModuleName ReAgent.Discovery Find-BinaryNinjaRoot { $null }
        Mock -ModuleName ReAgent.Discovery Get-MachineFacts {
            [PSCustomObject]@{ FreeDiskGb = 120; TotalRamGb = 32
                               IsVirtualMachine = $true; IsAdministrator = $true }
        }
    }

    It 'returns an object with every documented property even when nothing is installed' {
        $inv = Get-HostInventory
        foreach ($p in @('Python','PythonVersion','Jdk','Cdb','X64dbgRoot','GhidraRoot',
                         'BinaryNinjaRoot','ClaudeCode','FreeDiskGb','TotalRamGb',
                         'IsVirtualMachine','IsAdministrator')) {
            $inv.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'reports missing tools as null rather than throwing' {
        $inv = Get-HostInventory
        $inv.X64dbgRoot | Should -BeNullOrEmpty
        $inv.TotalRamGb | Should -Be 32
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: FAIL — `Find-X64dbgRoot` and `Get-HostInventory` are not defined.

- [ ] **Step 4: Write the minimal implementation**

Append to `src/ReAgent.Discovery.psm1`, before the `Export-ModuleMember` line, then extend that line:

```powershell
# Probed BEFORE PATH: `where.exe x64dbg` resolves the Chocolatey *shim*
# (C:\ProgramData\chocolatey\bin\x64dbg.exe), and deriving a release root from
# that yields C:\ProgramData\chocolatey - wrong. Verified on the host.
$Script:X64dbgCandidates = @(
    'C:\Tools\x64dbg\release\x64\x64dbg.exe',
    'C:\ProgramData\chocolatey\lib\x64dbg.vm\tools\release\x64\x64dbg.exe',
    'C:\ProgramData\chocolatey\lib\x64dbg\tools\release\x64\x64dbg.exe'
)

function Find-X64dbgRoot {
    <#
    .SYNOPSIS
        Locates the x64dbg 'release' directory that contains the x32 and x64 subtrees.
    .DESCRIPTION
        Returns the release root, not the executable, because the plugin must be
        installed into both release\x32\plugins and release\x64\plugins.
    #>
    [CmdletBinding()]
    param()

    # Known paths first, PATH second - see the comment on $Script:X64dbgCandidates.
    $exe = $null
    foreach ($c in $Script:X64dbgCandidates) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }
    if (-not $exe) {
        $found = Find-Executable -Name 'x64dbg'
        if ($found -and $found -notlike '*\chocolatey\bin\*') { $exe = $found }
    }
    if (-not $exe) { return $null }

    # <root>\release\x64\x64dbg.exe -> <root>\release
    return (Split-Path -Parent (Split-Path -Parent $exe))
}

function Find-GhidraRoot {
    <#
    .SYNOPSIS
        Locates the Ghidra installation directory.
    #>
    [CmdletBinding()]
    param()

    if ($env:GHIDRA_INSTALL_DIR -and (Test-Path -LiteralPath $env:GHIDRA_INSTALL_DIR)) {
        return $env:GHIDRA_INSTALL_DIR
    }
    # Chocolatey nests one level deeper than C:\Tools does: the FLARE-VM package
    # unzips to ...\lib\ghidra\tools\ghidra_<version>_PUBLIC. Verified on the host.
    foreach ($base in @('C:\Tools', 'C:\ProgramData\chocolatey\lib\ghidra\tools',
                        'C:\ProgramData\chocolatey\lib\ghidra.vm\tools')) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $hit = Get-ChildItem -LiteralPath $base -Directory -Filter 'ghidra_*' -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-GhidraVersion {
    <#
    .SYNOPSIS
        Extracts the Ghidra version from its installation directory name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GhidraRoot)

    if ((Split-Path -Leaf $GhidraRoot) -match 'ghidra_(\d+\.\d+(\.\d+)?)') {
        return [version]$Matches[1]
    }
    return $null
}

function Find-BinaryNinjaRoot {
    <#
    .SYNOPSIS
        Locates the Binary Ninja installation directory.
    #>
    [CmdletBinding()]
    param()

    $exe = Find-Executable -Name 'binaryninja'
    if ($exe) { return (Split-Path -Parent $exe) }

    # %LOCALAPPDATA%\Vector35 does not exist on this host; Program Files does.
    foreach ($c in @("$env:ProgramFiles\Vector35\BinaryNinja",
                     "$env:LOCALAPPDATA\Vector35\BinaryNinja")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-BinaryNinjaSettingsPath {
    <#
    .SYNOPSIS
        Returns the path to Binary Ninja's user settings.json.
    .DESCRIPTION
        The file may not exist yet on a fresh install; callers must handle that.
        Path confirmed against the host during Task 4 Step 1 (open item O3).
    #>
    [CmdletBinding()]
    param()
    return (Join-Path $env:APPDATA 'Binary Ninja\settings.json')
}

function Get-MachineFacts {
    <#
    .SYNOPSIS
        Collects RAM, free disk, VM status, and elevation. Exists as a mock seam.
    #>
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance Win32_ComputerSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $vmHints = @('VMware', 'VirtualBox', 'Virtual Machine', 'KVM', 'QEMU', 'Xen')

    [PSCustomObject]@{
        FreeDiskGb       = [math]::Round($disk.FreeSpace / 1GB, 1)
        TotalRamGb       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        IsVirtualMachine = [bool]($vmHints | Where-Object { $cs.Model -like "*$_*" -or $cs.Manufacturer -like "*$_*" })
        IsAdministrator  = $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Get-HostInventory {
    <#
    .SYNOPSIS
        Builds the complete host inventory consumed by every later phase.
    .DESCRIPTION
        Absent tools are reported as $null, never as an error. Phase 0 decides
        which absences are fatal; this function only observes.
    #>
    [CmdletBinding()]
    param()

    $python = Find-Executable -Name 'python'
    $ghidra = Find-GhidraRoot
    $bnRoot = Find-BinaryNinjaRoot
    $facts  = Get-MachineFacts

    [PSCustomObject]@{
        Python                  = $python
        PythonVersion           = if ($python) { Get-PythonVersion -PythonPath $python } else { $null }
        Jdk                     = Find-Executable -Name 'java'
        JdkVersion              = $null
        Cdb                     = Find-Executable -Name 'cdb'
        Uv                      = Find-Executable -Name 'uv'
        X64dbgRoot              = Find-X64dbgRoot
        GhidraRoot              = $ghidra
        GhidraVersion           = if ($ghidra) { Get-GhidraVersion -GhidraRoot $ghidra } else { $null }
        BinaryNinjaRoot         = $bnRoot
        BinaryNinjaSettingsPath = Get-BinaryNinjaSettingsPath
        BinaryNinjaVersion      = $null
        ClaudeCode              = Find-Executable -Name 'claude'
        FreeDiskGb              = $facts.FreeDiskGb
        TotalRamGb              = $facts.TotalRamGb
        IsVirtualMachine        = $facts.IsVirtualMachine
        IsAdministrator         = $facts.IsAdministrator
    }
}
```

Replace the existing export line with:

```powershell
Export-ModuleMember -Function Invoke-CommandLine, Find-Executable, Compare-VersionAtLeast, `
    Get-PythonVersion, Find-X64dbgRoot, Find-GhidraRoot, Get-GhidraVersion, `
    Find-BinaryNinjaRoot, Get-BinaryNinjaSettingsPath, Get-MachineFacts, Get-HostInventory
```

- [ ] **Step 5: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: PASS, 13 tests.

- [ ] **Step 6: Run the real inventory on the host and eyeball it**

Run:

```powershell
Import-Module .\src\ReAgent.Discovery.psm1 -Force
Get-HostInventory | Format-List
```

Expected: every installed tool resolves to a real path; absent ones are blank. **If a tool you know is installed shows as null, fix the discovery logic now** — every later phase depends on this being right.

- [ ] **Step 7: Run the linter and commit**

Run: `Invoke-ScriptAnalyzer -Path src/ -Settings PSScriptAnalyzerSettings.psd1 -Recurse`

```bash
git add src/ReAgent.Discovery.psm1 tests/ReAgent.Discovery.Tests.ps1
git commit -m "Add tool discovery and full host inventory"
```

---

## Task 5: Preflight hard blockers

**Files:**
- Modify: `src/ReAgent.Discovery.psm1`
- Modify: `tests/ReAgent.Discovery.Tests.ps1`

**Interfaces:**
- Consumes: `Get-HostInventory` from Task 4.
- Produces: `Test-Preflight -Inventory <object>` returning an array of blocker strings — empty when preflight passes; `Assert-Preflight -Inventory <object>` which throws with a joined, actionable message when blockers exist.

- [ ] **Step 1: Write the failing test**

Append to `tests/ReAgent.Discovery.Tests.ps1`:

```powershell
Describe 'Test-Preflight' {
    BeforeAll {
        function New-Inv {
            param($Admin = $true, $Vm = $true, $Claude = 'C:\claude.exe')
            [PSCustomObject]@{
                IsAdministrator = $Admin; IsVirtualMachine = $Vm; ClaudeCode = $Claude
                TotalRamGb = 32; FreeDiskGb = 100
            }
        }
    }

    It 'returns no blockers on a healthy host' {
        Test-Preflight -Inventory (New-Inv) | Should -BeNullOrEmpty
    }

    It 'blocks when not elevated' {
        (Test-Preflight -Inventory (New-Inv -Admin $false)) -join ';' |
            Should -BeLike '*Administrator*'
    }

    It 'blocks when Claude Code is absent' {
        (Test-Preflight -Inventory (New-Inv -Claude $null)) -join ';' |
            Should -BeLike '*Claude Code*'
    }

    It 'blocks when not on a virtual machine' {
        (Test-Preflight -Inventory (New-Inv -Vm $false)) -join ';' |
            Should -BeLike '*virtual machine*'
    }

    It 'reports every blocker at once rather than only the first' {
        (Test-Preflight -Inventory (New-Inv -Admin $false -Claude $null)).Count |
            Should -Be 2
    }
}

Describe 'Assert-Preflight' {
    It 'throws listing the blockers' {
        $inv = [PSCustomObject]@{
            IsAdministrator = $false; IsVirtualMachine = $true; ClaudeCode = 'x'
            TotalRamGb = 32; FreeDiskGb = 100
        }
        { Assert-Preflight -Inventory $inv } | Should -Throw '*Administrator*'
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: FAIL — `Test-Preflight` is not defined.

- [ ] **Step 3: Write the minimal implementation**

Append to `src/ReAgent.Discovery.psm1` and extend the export list with `Test-Preflight, Assert-Preflight`:

```powershell
function Test-Preflight {
    <#
    .SYNOPSIS
        Returns the list of hard blockers preventing this run, empty if none.
    .DESCRIPTION
        Every blocker is reported, not just the first, so one run surfaces all
        remediation the operator needs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $blockers = @()

    if (-not $Inventory.IsAdministrator) {
        $blockers += 'Not running as Administrator. Re-launch PowerShell with "Run as administrator".'
    }
    if (-not $Inventory.IsVirtualMachine) {
        $blockers += 'This does not look like a virtual machine. RE tooling must not be installed on a host OS.'
    }
    if (-not $Inventory.ClaudeCode) {
        $blockers += 'Claude Code was not found for the current user. It is a prerequisite, not installed by this script. Install it, then re-run.'
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        $blockers += "PowerShell $($PSVersionTable.PSVersion) is too old. 5.1 or later is required."
    }
    return $blockers
}

function Assert-Preflight {
    <#
    .SYNOPSIS
        Throws with a combined, actionable message when preflight blockers exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $blockers = Test-Preflight -Inventory $Inventory
    if ($blockers.Count -gt 0) {
        throw ("Preflight failed:`n  - " + ($blockers -join "`n  - "))
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1 -Output Detailed`
Expected: PASS, 19 tests.

- [ ] **Step 5: Confirm the Claude Code check resolves as the analyst user**

This is the trap from the spec's failure-modes table. Claude Code installs per-user to
`%USERPROFILE%\.local\bin`, so an elevated shell may resolve a different profile.
✅ Measured on this host: `C:\Users\user\.local\bin\claude.exe`, version **2.1.261**.

From an **elevated** prompt, confirm it still resolves:

```powershell
where.exe claude
$env:USERPROFILE
```

If `claude` does not resolve under elevation but does for your normal account, the elevated session is
looking at a different profile. Run the installer as the analyst user *with* elevation rather than as
a different administrator — and if you resolve it some other way, note it in `docs/mvp/MVP.md`'s log.

- [ ] **Step 6: Run the linter and commit**

Run: `Invoke-ScriptAnalyzer -Path src/ -Settings PSScriptAnalyzerSettings.psd1 -Recurse`

```bash
git add src/ReAgent.Discovery.psm1 tests/ReAgent.Discovery.Tests.ps1
git commit -m "Add preflight hard blocker checks"
```

---

## Task 6: Phase runner and entry point

**Files:**
- Modify: `src/ReAgent.Common.psm1`, `tests/ReAgent.Common.Tests.ps1`
- Modify: `Install-REAgent.ps1`

**Interfaces:**
- Consumes: `New-PhaseResult`, `Write-ReAgentLog` from Task 1; `Get-ReAgentExitCode` from Task 1.
- Produces: `Invoke-Phase -Phase <hashtable> -Force <switch> -Context <hashtable>` returning a phase result object. `$Phase` has keys `Id`, `Name`, `Fn`, `Test`. `Fn` and `Test` are script blocks taking `$Context`.

- [ ] **Step 1: Write the failing test**

Append to `tests/ReAgent.Common.Tests.ps1`:

```powershell
Describe 'Invoke-Phase' {
    It 'skips a phase whose Test already passes' {
        $ran = $false
        $phase = @{
            Id = 1; Name = 'Thing'
            Test = { $true }
            Fn   = { $script:ran = $true }
        }
        $r = Invoke-Phase -Phase $phase -Context @{}
        $r.Status | Should -Be 'skipped'
        $ran | Should -BeFalse
    }

    It 'runs a phase whose Test fails' {
        $phase = @{
            Id = 1; Name = 'Thing'
            Test = { $false }
            Fn   = { 'done' }
        }
        (Invoke-Phase -Phase $phase -Context @{}).Status | Should -Be 'ok'
    }

    It 'runs a passing phase anyway when -Force is given' {
        $phase = @{ Id = 1; Name = 'Thing'; Test = { $true }; Fn = { 'done' } }
        (Invoke-Phase -Phase $phase -Context @{} -Force).Status | Should -Be 'ok'
    }

    It 'records a failure without throwing' {
        $phase = @{ Id = 1; Name = 'Thing'; Test = { $false }; Fn = { throw 'boom' } }
        $r = Invoke-Phase -Phase $phase -Context @{}
        $r.Status | Should -Be 'failed'
        $r.ErrorMessage | Should -BeLike '*boom*'
    }

    It 'always records a duration' {
        $phase = @{ Id = 1; Name = 'Thing'; Test = { $false }; Fn = { Start-Sleep -Milliseconds 10 } }
        (Invoke-Phase -Phase $phase -Context @{}).DurationMs | Should -BeGreaterThan 0
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Common.Tests.ps1 -Output Detailed`
Expected: FAIL — `Invoke-Phase` is not defined.

- [ ] **Step 3: Write the minimal implementation**

Append to `src/ReAgent.Common.psm1` and add `Invoke-Phase` to the export list:

```powershell
function Invoke-Phase {
    <#
    .SYNOPSIS
        Runs one phase with logging, idempotency, timing, and failure isolation.
    .DESCRIPTION
        Calls the phase's Test block first; when it returns true and -Force was
        not given, the phase is skipped. A throwing phase is recorded as failed
        and does not stop the run — the caller decides what is a hard dependency.
    .PARAMETER Phase
        Hashtable with keys Id, Name, Test (scriptblock), Fn (scriptblock).
    .PARAMETER Context
        Shared state passed to both blocks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Phase,
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Force
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $already = & $Phase.Test $Context
    } catch {
        $already = $false
    }

    if ($already -and -not $Force) {
        $sw.Stop()
        Write-ReAgentLog -Level INFO -Message "Phase $($Phase.Id) ($($Phase.Name)): already satisfied, skipping."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'skipped' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    }

    Write-ReAgentLog -Level INFO -Message "Phase $($Phase.Id) ($($Phase.Name)): starting."
    try {
        $null = & $Phase.Fn $Context
        $sw.Stop()
        Write-ReAgentLog -Level INFO -Message "Phase $($Phase.Id) ($($Phase.Name)): ok in $($sw.ElapsedMilliseconds)ms."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'ok' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        Write-ReAgentLog -Level ERROR -Message "Phase $($Phase.Id) ($($Phase.Name)): FAILED - $msg"
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'failed' `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ErrorMessage $msg
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Common.Tests.ps1 -Output Detailed`
Expected: PASS, 10 tests.

- [ ] **Step 5: Write the entry point**

Replace `Install-REAgent.ps1` with the real entry point. Phase bodies are stubs that later tasks fill in; the table and dispatch are complete now.

```powershell
<#
.SYNOPSIS
    Wires Claude Code to x64dbg, Ghidra, Binary Ninja, and WinDbg via MCP on an existing FLARE VM.
.DESCRIPTION
    Adopt-and-reconcile: inventories the host, installs only what is missing, and
    generates all agent configuration from re-agent.config.json. Idempotent.
.NOTES
    RUN ONLY ON A VIRTUAL MACHINE. Requires Administrator.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\re-agent.config.json",
    [int[]] $Phases,
    [switch]$Force,
    [switch]$VerifyOnly,
    [switch]$Attended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in @('Common', 'Config', 'Discovery', 'Prereqs', 'Symbols',
                 'Tokens', 'Json', 'Servers', 'Generate', 'Verify', 'Manifest')) {
    Import-Module "$PSScriptRoot\src\ReAgent.$m.psm1" -Force
}

$config = Get-ReAgentConfig -Path $ConfigPath
$transcript = Join-Path $config.paths.stateRoot 'install.log'
$null = New-Item -ItemType Directory -Path $config.paths.stateRoot -Force
Start-Transcript -Path $transcript -Append

$context = @{ Config = $config; Inventory = $null; ServerResults = @(); VerifyResults = @() }

$phaseTable = @(
    @{ Id = 0; Name = 'Preflight'
       Test = { $false }
       Fn   = { param($c) $c.Inventory = Get-HostInventory; Assert-Preflight -Inventory $c.Inventory } }
    @{ Id = 1; Name = 'Prerequisites'
       Test = { param($c) Test-PrereqsSatisfied -Inventory $c.Inventory }
       Fn   = { param($c) Install-Prereqs -Inventory $c.Inventory } }
    @{ Id = 2; Name = 'Symbols'
       Test = { param($c) Test-SymbolsReady -Config $c.Config }
       Fn   = { param($c) Install-Symbols -Config $c.Config } }
    @{ Id = 3; Name = 'McpServers'
       Test = { $false }
       Fn   = { param($c) $c.ServerResults = Install-AllMcpServers -Config $c.Config -Inventory $c.Inventory } }
    @{ Id = 4; Name = 'AgentConfig'
       Test = { $false }
       Fn   = { param($c) Write-AgentConfiguration -Config $c.Config -ServerResults $c.ServerResults } }
    @{ Id = 5; Name = 'Verify'
       Test = { $false }
       Fn   = { param($c) $c.VerifyResults = Invoke-Verification -Config $c.Config -Attended:$Attended } }
    @{ Id = 6; Name = 'Manifest'
       Test = { $false }
       Fn   = { param($c) Write-Manifest -Context $c } }
)

$selected = if ($VerifyOnly) { $phaseTable | Where-Object { $_.Id -in @(5, 6) } }
            elseif ($Phases)  { $phaseTable | Where-Object { $_.Id -in $Phases } }
            else              { $phaseTable }

$results = @()
foreach ($p in $selected) {
    $r = Invoke-Phase -Phase $p -Context $context -Force:$Force
    $results += $r
    if ($r.Status -eq 'failed' -and $p.Id -eq 0) {
        $results[-1].Status = 'aborted'
        break
    }
}

Stop-Transcript
exit (Get-ReAgentExitCode -PhaseResults $results)
```

- [ ] **Step 6: Run the linter and commit**

Run: `Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse`
Expected: zero findings. The script will not *run* yet — the later modules do not exist — but it must lint clean.

```bash
git add src/ReAgent.Common.psm1 tests/ReAgent.Common.Tests.ps1 Install-REAgent.ps1
git commit -m "Add phase runner and script entry point"
```

---

## Task 7: Prerequisites module

**Files:**
- Create: `src/ReAgent.Prereqs.psm1`, `tests/ReAgent.Prereqs.Tests.ps1`

**Interfaces:**
- Consumes: `Compare-VersionAtLeast`, `Find-Executable`, `Invoke-CommandLine` from Tasks 3–4.
- Produces: `Get-MissingPrereqs -Inventory <object>` returning an array of names from the set `python`, `jdk`, `cdb`, `uv`; `Test-PrereqsSatisfied -Inventory <object>` returning a bool; `Install-Prereqs -Inventory <object>` performing the installs.

- [ ] **Step 1: Write the failing test**

Create `tests/ReAgent.Prereqs.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Prereqs.psm1" -Force
}

Describe 'Get-MissingPrereqs' {
    BeforeAll {
        function New-Inv {
            param($Py = 'C:\py.exe', $PyVer = [version]'3.11.0', $Jdk = 'C:\java.exe',
                  $Cdb = 'C:\cdb.exe', $Uv = 'C:\uv.exe', $Ghidra = 'C:\ghidra')
            [PSCustomObject]@{
                Python = $Py; PythonVersion = $PyVer; Jdk = $Jdk
                Cdb = $Cdb; Uv = $Uv; GhidraRoot = $Ghidra
            }
        }
    }

    It 'reports nothing missing on a fully provisioned host' {
        Get-MissingPrereqs -Inventory (New-Inv) | Should -BeNullOrEmpty
    }

    It 'reports python when it is absent' {
        Get-MissingPrereqs -Inventory (New-Inv -Py $null -PyVer $null) | Should -Contain 'python'
    }

    It 'reports python when it is present but older than 3.10' {
        Get-MissingPrereqs -Inventory (New-Inv -PyVer ([version]'3.9.7')) | Should -Contain 'python'
    }

    It 'reports cdb when it is absent' {
        Get-MissingPrereqs -Inventory (New-Inv -Cdb $null) | Should -Contain 'cdb'
    }

    It 'does not require a JDK when Ghidra is not installed' {
        Get-MissingPrereqs -Inventory (New-Inv -Jdk $null -Ghidra $null) | Should -Not -Contain 'jdk'
    }

    It 'requires a JDK when Ghidra is installed' {
        Get-MissingPrereqs -Inventory (New-Inv -Jdk $null) | Should -Contain 'jdk'
    }
}

Describe 'Test-PrereqsSatisfied' {
    It 'is true when nothing is missing' {
        $inv = [PSCustomObject]@{
            Python = 'x'; PythonVersion = [version]'3.11.0'; Jdk = 'x'
            Cdb = 'x'; Uv = 'x'; GhidraRoot = 'x'
        }
        Test-PrereqsSatisfied -Inventory $inv | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `Invoke-Pester -Path tests/ReAgent.Prereqs.Tests.ps1 -Output Detailed`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the minimal implementation**

Create `src/ReAgent.Prereqs.psm1`:

```powershell
Set-StrictMode -Version Latest

$Script:MinPython = [version]'3.10.0'

function Get-MissingPrereqs {
    <#
    .SYNOPSIS
        Returns the names of prerequisites this host is missing.
    .DESCRIPTION
        Node.js is deliberately absent from this list. Nothing in this build
        needs it - not any of the five MCP servers, not Claude Code.
        A JDK is required only when Ghidra is installed, since both Ghidra
        MCP servers run on it and nothing else here does.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $missing = @()

    if (-not $Inventory.Python -or
        -not (Compare-VersionAtLeast -Actual $Inventory.PythonVersion -Minimum $Script:MinPython)) {
        $missing += 'python'
    }
    if ($Inventory.GhidraRoot -and -not $Inventory.Jdk) { $missing += 'jdk' }
    if (-not $Inventory.Cdb) { $missing += 'cdb' }
    if (-not $Inventory.Uv)  { $missing += 'uv' }

    return $missing
}

function Test-PrereqsSatisfied {
    <#
    .SYNOPSIS
        True when no prerequisite is missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)
    return ((Get-MissingPrereqs -Inventory $Inventory).Count -eq 0)
}

function Install-Prereqs {
    <#
    .SYNOPSIS
        Installs only the prerequisites the host is missing.
    .DESCRIPTION
        Never modifies an existing interpreter's global site-packages; each MCP
        server gets its own virtual environment in a later phase.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Inventory)

    foreach ($item in (Get-MissingPrereqs -Inventory $Inventory)) {
        if (-not $PSCmdlet.ShouldProcess($item, 'Install prerequisite')) { continue }
        switch ($item) {
            'python' {
                Write-ReAgentLog -Level INFO -Message 'Installing Python 3.12 via winget.'
                Invoke-CommandLine -FilePath 'winget' -Arguments @(
                    'install', '--id', 'Python.Python.3.12', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements')
            }
            'uv' {
                Write-ReAgentLog -Level INFO -Message 'Installing uv via winget.'
                Invoke-CommandLine -FilePath 'winget' -Arguments @(
                    'install', '--id', 'astral-sh.uv', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements')
            }
            'jdk' {
                # Ghidra's own application.properties governs the version, not this
                # constant. Ghidra 12.1.2 declares java.min=21 with no max, and the
                # host's existing OpenJDK 25 is verified working - so this path is
                # a fallback for hosts without any JDK, not the expected route.
                Write-ReAgentLog -Level INFO -Message 'Installing Temurin JDK 21 via winget.'
                Invoke-CommandLine -FilePath 'winget' -Arguments @(
                    'install', '--id', 'EclipseAdoptium.Temurin.21.JDK', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements')
            }
            'cdb' {
                throw @'
cdb.exe was not found and cannot be installed unattended by this script.
Install the Windows SDK Debugging Tools, then re-run:
  winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart
Or install WinDbg from the Microsoft Store. Then ensure the debuggers directory
is on the machine PATH.
'@
            }
        }
    }
}

Export-ModuleMember -Function Get-MissingPrereqs, Test-PrereqsSatisfied, Install-Prereqs
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `Invoke-Pester -Path tests/ReAgent.Prereqs.Tests.ps1 -Output Detailed`
Expected: PASS, 7 tests.

- [ ] **Step 5: Confirm the JDK satisfies the installed Ghidra**

✅ Already measured: Ghidra **12.1.2** declares `application.java.min=21` with **no maximum**, and the
host's **OpenJDK 25** is verified working end-to-end (pyghidra 3.1.0 started the JVM and reported
`Application.getApplicationVersion() == 12.1.2`). `Get-MissingPrereqs` must therefore **not** report
`jdk` on this host.

To re-confirm after any Ghidra upgrade:

```powershell
Import-Module .\src\ReAgent.Discovery.psm1 -Force
$inv = Get-HostInventory
$inv.GhidraVersion
Get-Content (Join-Path $inv.GhidraRoot 'Ghidra\application.properties') |
    Select-String 'application.java'
```

Read `application.java.min` **and** `application.java.max`. A future Ghidra that sets a maximum could
make the installed JDK 25 too *new*, which is the failure mode a bare "21+" assumption would miss.

- [ ] **Step 6: Run the linter and commit**

```bash
git add src/ReAgent.Prereqs.psm1 tests/ReAgent.Prereqs.Tests.ps1
git commit -m "Add prerequisite detection and installation"
```

---

## Task 8: Symbols, tokens, and safe JSON merge

These three are grouped because each is small, pure, and independently tested, and nothing downstream can start without all three.

**Files:**
- Create: `src/ReAgent.Symbols.psm1`, `src/ReAgent.Tokens.psm1`, `src/ReAgent.Json.psm1`
- Create: `tests/ReAgent.Symbols.Tests.ps1`, `tests/ReAgent.Tokens.Tests.ps1`, `tests/ReAgent.Json.Tests.ps1`

**Interfaces:**
- Consumes: `Write-ReAgentLog`, `Invoke-CommandLine`.
- Produces:
  - `Get-SymbolPathValue -CacheDir <string> -Server <string>` returning the `SRV*...*...` string; `Test-SymbolsReady -Config <object>`; `Install-Symbols -Config <object>`.
  - `New-BearerToken` returning a 64-char hex string; `Save-ServerToken -Name <string> -Token <string> -TokenRoot <string>`; `Get-ServerToken -Name <string> -TokenRoot <string>` returning the token or `$null`; `Get-X64dbgToken -McpConfigPath <string>` returning the token or `$null`.
  - `Merge-JsonFile -Path <string> -Values <hashtable>` which backs up, merges, and writes.

- [ ] **Step 1: Write the failing tests**

Create `tests/ReAgent.Json.Tests.ps1`:

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/ReAgent.Json.psm1" -Force }

Describe 'Merge-JsonFile' {
    It 'creates the file when it does not exist' {
        $p = Join-Path $TestDrive 'settings.json'
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }
        (Get-Content $p -Raw | ConvertFrom-Json).'ui.mcp.enabled' | Should -BeTrue
    }

    It 'preserves keys it did not write' {
        $p = Join-Path $TestDrive 'settings2.json'
        '{ "analysis.mode": "full", "ui.theme": "dark" }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.enabled' = $true }
        $r = Get-Content $p -Raw | ConvertFrom-Json
        $r.'analysis.mode' | Should -Be 'full'
        $r.'ui.theme' | Should -Be 'dark'
        $r.'ui.mcp.enabled' | Should -BeTrue
    }

    It 'overwrites only the keys it was given' {
        $p = Join-Path $TestDrive 'settings3.json'
        '{ "ui.mcp.port": 1111, "keep": "me" }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ 'ui.mcp.port' = 24642 }
        $r = Get-Content $p -Raw | ConvertFrom-Json
        $r.'ui.mcp.port' | Should -Be 24642
        $r.keep | Should -Be 'me'
    }

    It 'writes a backup before modifying an existing file' {
        $p = Join-Path $TestDrive 'settings4.json'
        '{ "a": 1 }' | Set-Content $p
        Merge-JsonFile -Path $p -Values @{ b = 2 }
        (Get-ChildItem $TestDrive -Filter 'settings4.json.bak-*').Count |
            Should -BeGreaterThan 0
    }

    It 'refuses to write when the existing file is not valid JSON' {
        $p = Join-Path $TestDrive 'broken.json'
        'this is not json' | Set-Content $p
        { Merge-JsonFile -Path $p -Values @{ a = 1 } } | Should -Throw '*not valid JSON*'
    }
}
```

Create `tests/ReAgent.Tokens.Tests.ps1`:

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/ReAgent.Tokens.psm1" -Force }

Describe 'New-BearerToken' {
    It 'returns 64 hex characters' {
        New-BearerToken | Should -Match '^[0-9a-f]{64}$'
    }
    It 'returns a different value each call' {
        (New-BearerToken) | Should -Not -Be (New-BearerToken)
    }
}

Describe 'Save-ServerToken and Get-ServerToken' {
    It 'round-trips a token through disk' {
        Save-ServerToken -Name 'binaryninja' -Token 'abc123' -TokenRoot $TestDrive
        Get-ServerToken -Name 'binaryninja' -TokenRoot $TestDrive | Should -Be 'abc123'
    }
    It 'returns null for a server with no stored token' {
        Get-ServerToken -Name 'nothing' -TokenRoot $TestDrive | Should -BeNullOrEmpty
    }
}

Describe 'Get-X64dbgToken' {
    It 'reads the token the plugin generated' {
        $p = Join-Path $TestDrive 'mcp_config.json'
        '{ "IpAddress": "127.0.0.1", "Port": 9094, "AutoStart": true,
           "AuthToken": "plugin-owned-token" }' | Set-Content $p
        Get-X64dbgToken -McpConfigPath $p | Should -Be 'plugin-owned-token'
    }
    It 'returns null when the plugin has not run yet' {
        Get-X64dbgToken -McpConfigPath (Join-Path $TestDrive 'absent.json') |
            Should -BeNullOrEmpty
    }
}
```

Create `tests/ReAgent.Symbols.Tests.ps1`:

```powershell
BeforeAll { Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force }

Describe 'Get-SymbolPathValue' {
    It 'builds the SRV triple in the order the debugger expects' {
        Get-SymbolPathValue -CacheDir 'C:\re\symbols' -Server 'https://msdl.microsoft.com/download/symbols' |
            Should -Be 'SRV*C:\re\symbols*https://msdl.microsoft.com/download/symbols'
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `Invoke-Pester -Path tests/ReAgent.Json.Tests.ps1,tests/ReAgent.Tokens.Tests.ps1,tests/ReAgent.Symbols.Tests.ps1 -Output Detailed`
Expected: FAIL — none of the three modules exist.

- [ ] **Step 3: Write ReAgent.Json.psm1**

```powershell
Set-StrictMode -Version Latest

function Merge-JsonFile {
    <#
    .SYNOPSIS
        Merges keys into a JSON file, preserving everything already there.
    .DESCRIPTION
        Used for application settings files owned by someone else - Binary
        Ninja's settings.json above all. Backs the file up before writing and
        refuses to touch a file it cannot parse, because silently replacing an
        operator's settings is worse than failing.
    .PARAMETER Path
        The JSON file. Created if absent.
    .PARAMETER Values
        Keys to set. Existing keys not named here are left untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $existing = @{}
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw.Trim()) {
            try {
                $parsed = $raw | ConvertFrom-Json
            } catch {
                throw "'$Path' is not valid JSON, so it cannot be merged into safely. Fix or move the file, then re-run."
            }
            foreach ($p in $parsed.PSObject.Properties) { $existing[$p.Name] = $p.Value }
        }
        $backup = "$Path.bak-$((Get-Date).ToString('yyyyMMddHHmmss'))"
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-ReAgentLog -Level INFO -Message "Backed up '$Path' to '$backup'."
    } else {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
    }

    foreach ($k in $Values.Keys) { $existing[$k] = $Values[$k] }

    if ($PSCmdlet.ShouldProcess($Path, 'Merge JSON settings')) {
        ([PSCustomObject]$existing) | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

Export-ModuleMember -Function Merge-JsonFile
```

- [ ] **Step 4: Write ReAgent.Tokens.psm1**

```powershell
Set-StrictMode -Version Latest

function New-BearerToken {
    <#
    .SYNOPSIS
        Generates a cryptographically random bearer token as lowercase hex.
    .DESCRIPTION
        Defaults to 32 bytes (64 hex chars). x64dbg's plugin uses 16 bytes
        (32 hex chars) for its own tokens, so pre-seeded values pass -ByteCount 16
        to match the format the plugin would otherwise have generated itself.
    #>
    [CmdletBinding()]
    param([ValidateRange(16, 64)][int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try   { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Save-ServerToken {
    <#
    .SYNOPSIS
        Persists a server's bearer token with an ACL restricted to the current user.
    .DESCRIPTION
        DPAPI is deliberately not used: its blobs are machine and user bound and
        would not survive being cloned or read by another account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    if (-not (Test-Path -LiteralPath $TokenRoot)) {
        $null = New-Item -ItemType Directory -Path $TokenRoot -Force
    }
    $path = Join-Path $TokenRoot "$Name.token"
    Set-Content -LiteralPath $path -Value $Token -Encoding ASCII -NoNewline

    $acl = Get-Acl -LiteralPath $path
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $path -AclObject $acl
}

function Get-ServerToken {
    <#
    .SYNOPSIS
        Reads a previously stored bearer token, or $null if there is none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    $path = Join-Path $TokenRoot "$Name.token"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw).Trim()
}

function Get-X64dbgToken {
    <#
    .SYNOPSIS
        Reads the bearer token that the x64dbg MCP plugin generated for itself.
    .DESCRIPTION
        The plugin owns this token; the installer must never invent one. Returns
        $null when the plugin has not yet run and written mcp_config.json.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$McpConfigPath)

    if (-not (Test-Path -LiteralPath $McpConfigPath)) { return $null }
    try {
        $cfg = Get-Content -LiteralPath $McpConfigPath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    # The field is 'AuthToken' - verified against src/core/config.zig upstream.
    if ($cfg.PSObject.Properties.Name -contains 'AuthToken') { return $cfg.AuthToken }
    return $null
}

Export-ModuleMember -Function New-BearerToken, Save-ServerToken, Get-ServerToken, Get-X64dbgToken
```

- [ ] **Step 5: Write ReAgent.Symbols.psm1**

```powershell
Set-StrictMode -Version Latest

function Get-SymbolPathValue {
    <#
    .SYNOPSIS
        Builds the _NT_SYMBOL_PATH value: downstream cache first, server second.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$Server
    )
    return "SRV*$CacheDir*$Server"
}

function Test-SymbolsReady {
    <#
    .SYNOPSIS
        True when _NT_SYMBOL_PATH is set machine-wide and the cache holds a PDB.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $want = Get-SymbolPathValue -CacheDir $Config.paths.symbolCache -Server $Config.symbols.server
    $have = [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH', 'Machine')
    if ($have -ne $want) { return $false }
    if (-not (Test-Path -LiteralPath $Config.paths.symbolCache)) { return $false }

    $pdbs = Get-ChildItem -LiteralPath $Config.paths.symbolCache -Recurse -Filter '*.pdb' `
                -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$pdbs
}

function Install-Symbols {
    <#
    .SYNOPSIS
        Sets _NT_SYMBOL_PATH machine-wide and pre-warms the cache.
    .DESCRIPTION
        Without a warm cache the agent reasons about unnamed addresses, which
        degrades every WinDbg answer. Logs any pre-existing value before
        overwriting, since the operator may have set it deliberately.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Config)

    $existing = [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH', 'Machine')
    if ($existing) {
        Write-ReAgentLog -Level WARN -Message "Replacing existing _NT_SYMBOL_PATH: '$existing'"
    }

    $value = Get-SymbolPathValue -CacheDir $Config.paths.symbolCache -Server $Config.symbols.server
    if ($PSCmdlet.ShouldProcess('_NT_SYMBOL_PATH', "Set to $value")) {
        [Environment]::SetEnvironmentVariable('_NT_SYMBOL_PATH', $value, 'Machine')
        $env:_NT_SYMBOL_PATH = $value
    }

    if (-not (Test-Path -LiteralPath $Config.paths.symbolCache)) {
        $null = New-Item -ItemType Directory -Path $Config.paths.symbolCache -Force
    }

    $symchk = Find-Executable -Name 'symchk'
    if (-not $symchk) {
        Write-ReAgentLog -Level WARN -Message 'symchk.exe not found; skipping symbol pre-warm. WinDbg output will show unnamed addresses until the cache fills.'
        return
    }

    foreach ($dll in $Config.symbols.prewarm) {
        $full = Join-Path $env:SystemRoot "System32\$dll"
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Write-ReAgentLog -Level INFO -Message "Pre-warming symbols for $dll."
        Invoke-CommandLine -FilePath $symchk -Arguments @('/r', $full, '/s', $value) | Out-Null
    }
}

Export-ModuleMember -Function Get-SymbolPathValue, Test-SymbolsReady, Install-Symbols
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `Invoke-Pester -Path tests/ -Output Detailed`
Expected: PASS, all tests across all files.

- [ ] **Step 7: Run the linter and commit**

```bash
git add src/ReAgent.Json.psm1 src/ReAgent.Tokens.psm1 src/ReAgent.Symbols.psm1 tests/
git commit -m "Add symbol path setup, bearer tokens, and safe JSON merge"
```

---

**Remaining tasks (9–16) continue in the same structure.** They are:

- **Task 9** — Servers dispatcher, the `venv-stdio` handler (mcp-windbg) and the new **`venv-http`**
  handler (pyghidra-mcp, including the logon Scheduled Task and the chromadb model pre-warm). Closes the
  first full chain end-to-end. The probe in `MVP_FINDINGS.md` §4 is the reference implementation — this
  task is packaging work, not discovery. Also creates `C:\re\scratch\test.dmp` for the WinDbg check.
- **Task 10** — The `gui-builtin-http` handler for Binary Ninja: capability probe for `ui.mcp.enabled`,
  merge four settings, and surface the **per-session `MCP > Start Server`** requirement everywhere it
  matters (manifest manual steps, tier-2 prompt, `CLAUDE.md`).
- **Task 11** — The `plugin-inproc` handler for x64dbg: download and hash-verify v1.3, deploy the `dist/`
  tree to **both** architectures, and **pre-seed both `mcp_config.json` files** with `IpAddress`, `Port`,
  `AutoStart` and a 32-hex-char `AuthToken`. First step: confirm on the host whether that file belongs
  beside `x64dbg.exe` or beside the `.dp64` — the only open question left, and it fails silently.
- **Task 12** — The `gui-plugin-http` handler for GhidraMCP: compare `maxGhidraVersion` against the
  discovered Ghidra version and record `not-installed` on mismatch, which is the expected outcome here.
- **Task 13** — Generate `.mcp.json`, `.claude/settings.json` (**with `enableAllProjectMcpServers`**) and
  `CLAUDE.md`. Emit the mixed stdio/HTTP shapes, and omit the `Authorization` header for pyghidra-mcp.
- **Task 14** — Tier-1 unattended verification. Live calls, not handshakes: `decompile_function` with
  **`name_or_address`** against the program path from `list_project_binaries`, and `run_cdb_command lm`
  against the generated dump. Must distinguish ⏸ Pending-approval from a real connection failure.
- **Task 15** — Tier-2 attended verification and the `not-testable` status, covering **both** x64dbg
  servers and Binary Ninja's per-session start.
- **Task 16** — Manifest (including the pyghidra-mcp auth exemption and every resolved open item),
  end-to-end idempotency test, and the final acceptance run.

These eight are still summaries. Say the word and I will expand them to the same TDD step-by-step detail
as Tasks 1–8 — the research they depend on is now done, so the expansion is mechanical.
