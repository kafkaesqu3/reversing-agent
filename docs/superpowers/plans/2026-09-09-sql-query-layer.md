# SQL Query Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and wire two MCP servers — `pdbsql` (Windows PDB symbol files as SQL) and
`ghidrasql` (a Ghidra program database as SQL) — so the agent pushes filters down into a query
instead of pulling functions into context.

**Architecture:** Both are pinned native Windows binaries serving MCP over **SSE**, launched by
logon Scheduled Tasks. A new install `kind` of `native-sse` extracts a hash-verified release
zip; the existing launcher, restart and readiness machinery is reused unchanged. `mcp_probe.py`
gains an SSE transport. Both servers run read-only, which is what makes their single `*_query`
tool classifiable for the agent gate.

**Tech Stack:** PowerShell 5.1 modules under `src/`, Pester 5.5.0+ under `tests/`, Python for
`tools/mcp_probe.py`, Gradle 8.5+ and JDK 21+ for the one vendor-time extension build.

**Spec:** `docs/superpowers/specs/2026-09-09-sql-query-layer-design.md`

## Global Constraints

- **Branch:** `feat/sql-query-layer`, based on `main` (`a734f37`).
- **Task 1 is a gate.** Tasks 8 and 9 are stage 2 and MUST NOT be started until Task 1 has
  recorded a pass. If Task 1 fails, stop, report, and deliver stage 1 only.
- **Never run the real installer.** Phase functions are exercised through tests with the host
  mocked. The only exceptions are the explicitly-marked live steps in Tasks 1, 7 and 9.
- **`Z:` is an SMB share: `Edit`/`Write` fail with `ENOENT fchmod` when overwriting an existing
  file.** Create new files with `Write`; patch existing files with a Python script run through
  `C:\Python313\python.exe`.
- **Never pass JSON as a native command argument from PowerShell 5.1** — it strips the double
  quotes. Write it to a file. See `Invoke-McpProbe`'s `-Calls`.
- **The catalog is the authority** for whether a tool exists. Never hand-list a tool name that
  is not in `data/tool-catalog.json`.
- **Reuse `auth: "none"` + `authExemptReason`.** The config schema already expresses an
  unauthenticated server that way — `pyghidra-mcp` does exactly this. The spec §6 sketch
  invented a new `authExempt` boolean; **do not add it.** This is a deliberate correction to
  the spec, recorded in the "Deviations from the spec" section at the end of this plan.
- **PowerShell 5.1 only.** No `??`, no `?:`, no three-argument `Join-Path`.
- Hard limits: ≤100 lines/function, cyclomatic complexity ≤8, ≤5 positional params, 100-char
  lines, comment-based help on every exported function.
- Zero warnings from PSScriptAnalyzer. Fix, or inline-suppress with a justification comment.
- New verification checks are `Q`-prefixed (`Q0`, `Q1`) so they never read as the skills gate's
  `G0`–`G4` or the agent gate's `A0`–`A4`.
- **Locked decision IDs are `SQ1`–`SQ7`** in the spec. Do not confuse `SQ1` (staging) with `Q1`
  (the PDB-path check).
- Every generated file is written through `Write-FileIfChanged` so a steady-state run touches
  no timestamp.
- Commit after each task. Imperative mood, ≤72-char subject, **no AI attribution lines**.

---

## File Structure

| File | Responsibility |
|---|---|
| `tools/Build-LibGhidraExtension.ps1` | **Create.** Vendor-time build of the `LibGhidraHost` extension against this host's Ghidra, with the version-stamp assertion. |
| `tests/BuildLibGhidraExtension.Tests.ps1` | **Create.** Unit tests for the stamp assertion. |
| `tools/mcp_probe.py` | **Modify.** Add `--transport=sse`. |
| `src/ReAgent.Config.psm1` | **Modify.** Validate `transport: sse` and the `pdb` block. |
| `src/ReAgent.Symbols.psm1` | **Modify.** `Resolve-PdbPath` walks the symbol-server GUID tree. |
| `src/ReAgent.Servers.psm1` | **Modify.** `Install-NativeSseServer` and the `native-sse` dispatcher branch. |
| `src/ReAgent.Verify.psm1` | **Modify.** Transport-aware probing, plus checks `Q0` and `Q1`. |
| `data/tool-catalog.json` | **Modify.** Entries and classifications for both servers. |
| `re-agent.config.json` | **Modify.** Two `mcpServers` entries; the `verifier` and `static-analyst` grants. |

---

### Task 1: Prove the LibGhidraHost version stamp — THE STAGE-2 GATE

**This task decides whether stage 2 exists.** The prebuilt `libghidra-extension-*.zip` releases
declare an exact Ghidra version — `12.0.4` for v0.0.4–v0.0.6, `12.1.3` for v0.0.7 — and this
host runs **12.1.2**, which matches neither. Ghidra compares that string exactly and rejects
mismatches; it is the same failure that keeps `GhidraMCP 1.4` disabled in this repo.

Spec §3.6 argues the lock does not bind, because the *source* carries `version=@extversion@`
and Ghidra's own `support/buildExtension.gradle` substitutes the version of the distribution
being built against. **That argument has never been executed.** This task executes it.

**Files:**
- Create: `tools/Build-LibGhidraExtension.ps1`
- Create: `tests/BuildLibGhidraExtension.Tests.ps1`

**Interfaces:**
- Consumes: `Get-GhidraVersion`, `Find-GhidraRoot` (both already exported from
  `src/ReAgent.Discovery.psm1`).
- Produces:
  - `Assert-StampedExtensionVersion -ZipPath <string> -ExpectedVersion <string>` → returns the
    stamped version string on success; throws on mismatch, on an unsubstituted token, or on a
    zip with no `extension.properties`.

- [ ] **Step 1: Write the failing tests**

Create `tests/BuildLibGhidraExtension.Tests.ps1`:

```powershell
BeforeAll {
    . "$PSScriptRoot/../tools/Build-LibGhidraExtension.ps1" -DotSourceOnly

    function New-FixtureZip {
        param([string]$VersionLine)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ext-" + [guid]::NewGuid())
        $inner = Join-Path $dir 'LibGhidraHost'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        $props = "name=LibGhidraHost`nauthor=libghidra`n$VersionLine`n"
        [IO.File]::WriteAllText((Join-Path $inner 'extension.properties'), $props)
        $zip = "$dir.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        Remove-Item -LiteralPath $dir -Recurse -Force
        return $zip
    }
}

Describe 'Assert-StampedExtensionVersion' {
    It 'returns the version when the build stamped the expected one' {
        $zip = New-FixtureZip -VersionLine 'version=12.1.2'
        try {
            Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' |
                Should -Be '12.1.2'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the token was never substituted' {
        # THE failure this gate exists to catch: the build ran but Ghidra's
        # buildExtension.gradle never applied ReplaceTokens, so the extension
        # would ship claiming a literal '@extversion@' and Ghidra would reject it.
        $zip = New-FixtureZip -VersionLine 'version=@extversion@'
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*@extversion@*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the stamp is a different Ghidra version' {
        # Reproduces the prebuilt-release situation: a 12.1.3 extension on a 12.1.2 host.
        $zip = New-FixtureZip -VersionLine 'version=12.1.3'
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*12.1.3*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }

    It 'throws when the zip carries no extension.properties at all' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("ext-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'LibGhidraHost') -Force | Out-Null
        $zip = "$dir.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
        Remove-Item -LiteralPath $dir -Recurse -Force
        try {
            { Assert-StampedExtensionVersion -ZipPath $zip -ExpectedVersion '12.1.2' } |
                Should -Throw '*extension.properties*'
        } finally { Remove-Item -LiteralPath $zip -Force }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/BuildLibGhidraExtension.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `tools/Build-LibGhidraExtension.ps1` does not exist.

- [ ] **Step 3: Create the script**

Create `tools/Build-LibGhidraExtension.ps1`:

```powershell
<#
.SYNOPSIS
    Builds the LibGhidraHost Ghidra extension against this host's Ghidra.
.DESCRIPTION
    A maintainer-path script. It has a network and is never run by the
    installer, which stays offline (spec SQ6).

    The prebuilt libghidra-extension-*.zip releases declare one exact Ghidra
    version and Ghidra rejects any mismatch, so a release zip is unusable on a
    host whose Ghidra differs by even a patch level. The source instead ships
    'version=@extversion@' and Ghidra's own support/buildExtension.gradle
    substitutes the version of the distribution being built against. Building
    locally therefore produces an extension stamped for THIS host.

    Assert-StampedExtensionVersion is what makes that trustworthy: a build that
    silently failed to substitute would otherwise ship a literal '@extversion@'.
.PARAMETER GhidraRoot
    Ghidra distribution to build against. Defaults to discovery.
.PARAMETER SourceRoot
    Checkout of 0xeb/libghidra at the pinned commit.
.PARAMETER DotSourceOnly
    Define the functions and return, so tests can load them without building.
.EXAMPLE
    .\tools\Build-LibGhidraExtension.ps1 -SourceRoot .vendor-cache\libghidra
#>
[CmdletBinding()]
param(
    [string]$GhidraRoot,
    [string]$SourceRoot,
    [switch]$DotSourceOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-StampedExtensionVersion {
    <#
    .SYNOPSIS
        Asserts a built extension zip is stamped for the expected Ghidra version.
    .DESCRIPTION
        Three distinct failures, each reported separately because each has a
        different remedy: no extension.properties means the build produced
        something that is not a Ghidra extension; a surviving '@extversion@'
        means buildExtension.gradle never ran its ReplaceTokens filter; a
        different version means the build targeted another distribution.
    .PARAMETER ZipPath
        The built extension zip, from Gradle's dist/ directory.
    .PARAMETER ExpectedVersion
        The Ghidra version this host runs, e.g. '12.1.2'.
    .OUTPUTS
        [string] The stamped version, when it matches.
    .EXAMPLE
        Assert-StampedExtensionVersion -ZipPath dist\LibGhidraHost.zip -ExpectedVersion '12.1.2'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like '*extension.properties' } |
            Select-Object -First 1
        if ($null -eq $entry) {
            throw ("'$ZipPath' contains no extension.properties. Gradle did not produce a " +
                'Ghidra extension; check the buildExtension task output.')
        }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }

    $found = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*version\s*=\s*(.+?)\s*$') { $found = $Matches[1] }
    }

    if ($found -eq '@extversion@') {
        throw ("'$ZipPath' still carries the literal token '@extversion@'. Ghidra's " +
            'support/buildExtension.gradle did not run its ReplaceTokens filter, so this ' +
            'extension is not stamped for any Ghidra version and will be rejected.')
    }
    if ($found -ne $ExpectedVersion) {
        throw ("'$ZipPath' is stamped for Ghidra '$found' but this host runs " +
            "'$ExpectedVersion'. Ghidra matches that string exactly and will reject the " +
            'extension. Rebuild with -PGHIDRA_INSTALL_DIR pointing at this host''s Ghidra.')
    }
    return $found
}

function Invoke-ExtensionBuild {
    <#
    .SYNOPSIS
        Runs Gradle's buildExtension task and returns the built zip's path.
    .PARAMETER SourceRoot
        Checkout of 0xeb/libghidra at the pinned commit.
    .PARAMETER GhidraRoot
        Ghidra distribution to build against.
    .OUTPUTS
        [string] Path to the built zip under dist/.
    .EXAMPLE
        Invoke-ExtensionBuild -SourceRoot .vendor-cache\libghidra -GhidraRoot C:\ghidra
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$GhidraRoot
    )

    if (-not (Get-Command gradle -ErrorAction SilentlyContinue)) {
        throw ('Gradle is not on PATH. Ghidra 12.1.2 needs Gradle 8.5 or newer with no ' +
            'upper bound; install it with: choco install gradle')
    }
    $project = Join-Path $SourceRoot 'ghidra-extension'
    if (-not (Test-Path -LiteralPath $project)) {
        throw "No ghidra-extension directory under '$SourceRoot'."
    }
    Push-Location $project
    try {
        & gradle buildExtension "-PGHIDRA_INSTALL_DIR=$GhidraRoot" 2>&1 | Write-Verbose
        if ($LASTEXITCODE -ne 0) {
            throw ("gradle buildExtension failed with exit code $LASTEXITCODE. If it failed " +
                'to compile, the Ghidra Java API moved between this distribution and the ' +
                'one upstream targets - that is the real blocker, not the version stamp.')
        }
    } finally { Pop-Location }

    $zip = Get-ChildItem (Join-Path $project 'dist') -Filter '*.zip' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $zip) { throw "gradle succeeded but produced no zip under '$project\dist'." }
    return $zip.FullName
}

if ($DotSourceOnly) { return }

if (-not $GhidraRoot) { $GhidraRoot = Find-GhidraRoot }
$expected = Get-GhidraVersion -GhidraRoot $GhidraRoot
Write-Host "Building LibGhidraHost against Ghidra $expected at $GhidraRoot"
$built = Invoke-ExtensionBuild -SourceRoot $SourceRoot -GhidraRoot $GhidraRoot
$stamped = Assert-StampedExtensionVersion -ZipPath $built -ExpectedVersion $expected
Write-Host "PASS: '$built' is stamped version=$stamped"
Write-Host ("SHA-256: " + (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/BuildLibGhidraExtension.Tests.ps1 -Output Detailed"
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Run the analyzer**

Run:
```bash
powershell.exe -NoProfile -Command "Invoke-ScriptAnalyzer -Path tools/Build-LibGhidraExtension.ps1 -Settings PSScriptAnalyzerSettings.psd1"
```
Expected: no output.

- [x] **Step 6: Commit the script before running the real build**

```bash
git add tools/Build-LibGhidraExtension.ps1 tests/BuildLibGhidraExtension.Tests.ps1
git commit -m "Add the LibGhidraHost extension build and its version assertion"
```

- [x] **Step 7: THE GATE — install Gradle and run the real build**

This step mutates the host: it installs Gradle and writes a checkout into `.vendor-cache`.
Both are reversible.

Run:
```bash
powershell.exe -NoProfile -Command "choco install gradle -y" 
git clone https://github.com/0xeb/libghidra .vendor-cache/libghidra
git -C .vendor-cache/libghidra checkout v0.0.7
powershell.exe -NoProfile -Command ".\tools\Build-LibGhidraExtension.ps1 -SourceRoot .vendor-cache\libghidra -Verbose"
```

Expected on success: `PASS: '...\dist\ghidra_12.1.2_PUBLIC_<date>_LibGhidraHost.zip' is
stamped version=12.1.2`, followed by a SHA-256.

**Record the exact output — the stamped version and the hash — in the execution ledger.**

- [x] **Step 8: Evaluate the gate and branch the plan**

Three outcomes. Take exactly one.

| Outcome | Meaning | Action |
|---|---|---|
| `PASS: ... stamped version=12.1.2` | Spec §3.6 holds. The version lock does not bind. | **Stage 2 is live.** Record the built zip's SHA-256 in the ledger for Task 9. Continue to Task 2. |
| `gradle buildExtension failed ... failed to compile` | The Ghidra Java API moved between 12.1.2 and the 12.1.3 upstream targets. This is real API drift, not a stamp problem, and it is the failure spec §3.8 predicted. | **Strike Tasks 8 and 9.** Record the compiler output verbatim. Continue to Task 2 and deliver stage 1 only. Re-open when upstream publishes a release targeting 12.1.2, or when Ghidra is upgraded to 12.1.3 — noting that upgrade is its own decision, since `pyghidra-mcp` is verified against 12.1.2. |
| `still carries the literal token '@extversion@'` | Gradle ran but the substitution did not. | **Do not proceed to stage 2 and do not hand-edit the file.** A hand-stamped extension bypasses the version check without proving API compatibility. Record and treat as the failure case above. |

- [x] **Step 9: Commit the gate outcome**

**GATE OUTCOME: PASS.** Spec section 3.6 holds - the version lock does not bind. Recorded output:

```
This host's Ghidra: 12.1.2 at C:\ProgramData\chocolatey\lib\ghidra	ools\ghidra_12.1.2_PUBLIC
PASS: stamped version=12.1.2
SHA-256: 9C6ECFC592AFA73438DDE6964A29BF36CB8BFE1BBAE44B2BC8424CE0F2C42EEF
```

Built from `0xeb/libghidra` at tag `v0.0.7` via `gradle buildExtension`, Gradle 9.7.1, against
this host's real Ghidra 12.1.2 install. **Stage 2 is live** - Tasks 8 and 9 proceed. This
SHA-256 is Task 9's zip for `ghidrasql`'s companion extension install.

(Process note: the wrapping `Build-LibGhidraExtension.ps1 -Verbose` invocation's own
`gradle buildExtension ... 2>&1 | Write-Verbose` pipe hung after the build actually completed -
`gradle --status` showed the daemon IDLE and the dist zip already on disk within about a minute
of starting, while the outer PowerShell pipe never received EOF because the resident Gradle
daemon keeps the inherited output handle open. Confirmed the artifact directly and ran
`Assert-StampedExtensionVersion` by hand against it instead of waiting on the hung wrapper. The
gate script's own logic is correct and already covered by Task 1's unit tests; this is a
PowerShell/Gradle-daemon process-handle interaction outside the script's control, worth a
one-line note for a future maintainer running this by hand: expect the wrapper's own console
output to possibly never flush, and check for the dist zip directly if it seems to hang after
Gradle itself reports success.)

```bash
git add docs/superpowers/plans/2026-09-09-sql-query-layer.md
git commit -m "Record the LibGhidraHost version-stamp gate outcome"
```

---

### Task 2: Teach the probe SSE

Both servers serve MCP over SSE. `mcp_probe.py` speaks streamable-http and stdio only, so it
cannot verify either of them — `POST /sse` answers `405 Method Not Allowed`.

**Files:**
- Modify: `tools/mcp_probe.py`
- Test: `tests/ReAgent.Verify.Tests.ps1`

**Interfaces:**
- Produces: `mcp_probe.py --transport=sse --url=<url>` behaving exactly like `--transport=http`
  — same JSON result shape, same `ok` field, same exit-code contract.

- [ ] **Step 1: Write the failing test**

`tools/mcp_probe.py` is a Python script with no Python test harness in this repo; the
established pattern is a source assertion in Pester plus a live check. Follow it.

Append to `tests/ReAgent.Verify.Tests.ps1`, inside the existing `Describe 'the probe script'`
block:

```powershell
    It 'offers an sse transport for the SQL-layer servers' {
        # pdbsql and ghidrasql serve MCP over SSE, not streamable HTTP. Without
        # this the probe answers 405 and a healthy server reads as unreachable -
        # the same class of false negative as HANDOFF defect 3.
        $src = Get-Content (Join-Path $PSScriptRoot '..\tools\mcp_probe.py') -Raw
        $src | Should -BeLike '*sse_client*'
        $src | Should -BeLike '*"sse"*'
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Verify.Tests.ps1 -Output Detailed"
```
Expected: FAIL on the new test — `sse_client` is absent.

- [ ] **Step 3: Add the transport**

`tools/mcp_probe.py` is an existing file on the `Z:` share — patch it with a Python script, not
`Edit`. Write `tools/patch-probe.py` (delete it after the commit):

```python
import io

p = 'tools/mcp_probe.py'
src = io.open(p, encoding='utf-8', newline='').read()

anchor = 'async def probe_http(args):'
addition = '''def sse_transport(url, headers):
    """Open an SSE transport.

    pdbsql and ghidrasql serve MCP over SSE: GET <url> streams an
    `event: endpoint` naming a session-scoped POST path, and JSON-RPC then
    flows to that path. This is not streamable-http and the two are not
    interchangeable - posting to an SSE endpoint answers 405.
    """
    from mcp.client.sse import sse_client

    return sse_client(url, headers=headers)


async def probe_sse(args):
    from mcp import ClientSession

    async with sse_transport(args.url, parse_pairs(args.header)) as streams:
        async with ClientSession(streams[0], streams[1]) as session:
            return await run_checks(session, args)


'''
assert anchor in src, 'probe_http anchor missing'
src = src.replace(anchor, addition + anchor, 1)

old_choices = 'parser.add_argument("--transport", required=True, choices=["stdio", "http"])'
new_choices = ('parser.add_argument("--transport", required=True,\n'
               '                        choices=["stdio", "http", "sse"])')
assert old_choices in src, 'transport choices anchor missing'
src = src.replace(old_choices, new_choices, 1)

old_req = 'if args.transport == "http" and not args.url:'
new_req = 'if args.transport in ("http", "sse") and not args.url:'
assert old_req in src, 'url requirement anchor missing'
src = src.replace(old_req, new_req, 1)

old_dispatch = ('    coroutine = probe_stdio(args) if args.transport == "stdio" '
                'else probe_http(args)')
new_dispatch = ('    if args.transport == "stdio":\n'
                '        coroutine = probe_stdio(args)\n'
                '    elif args.transport == "sse":\n'
                '        coroutine = probe_sse(args)\n'
                '    else:\n'
                '        coroutine = probe_http(args)')
assert old_dispatch in src, 'dispatch anchor missing'
src = src.replace(old_dispatch, new_dispatch, 1)

io.open(p, 'w', encoding='utf-8', newline='').write(src)
print('patched')
```

Run: `C:\Python313\python.exe tools/patch-probe.py`

- [ ] **Step 4: Run to verify the test passes**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Verify.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Verify the timeout path by hand**

A server that accepts the SSE connection but never emits `event: endpoint` must surface as a
timeout, not a hang. Confirm the probe honours `--timeout` against a listener that never
speaks:

Run:
```bash
powershell.exe -NoProfile -Command "$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,9109); $l.Start(); Start-Sleep 30; $l.Stop()" &
C:/re/mcp/venvs/pyghidra-mcp/Scripts/python.exe tools/mcp_probe.py --transport=sse --url=http://127.0.0.1:9109/sse --timeout=5
```
Expected: JSON with `"ok": false` and an error mentioning a timeout, returned within roughly
five seconds. Exit code 0 — a probe failure is a server verdict, not a probe crash.

- [ ] **Step 6: Delete the patch script and commit**

```bash
rm tools/patch-probe.py
git add tools/mcp_probe.py tests/ReAgent.Verify.Tests.ps1
git commit -m "Teach the MCP probe the SSE transport"
```

---

### Task 3: Validate the sse transport and the pdb block at config load

**Files:**
- Modify: `src/ReAgent.Config.psm1`
- Test: `tests/ReAgent.Config.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Test-McpServerTransport -Config <object>` → throws on an invalid `transport`, on an
  HTTP-family server that is neither authenticated nor exempt, or on a `pdb` block missing its
  `module`. Returns silently otherwise.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Config.Tests.ps1`:

```powershell
Describe 'Test-McpServerTransport' {
    function Get-TestServerConfig {
        param($Servers)
        [PSCustomObject]@{ mcpServers = $Servers }
    }
    function Get-TestServer {
        param($Name = 'pdbsql', $Transport = 'sse', $Auth = 'none',
              $Reason = 'upstream MCP endpoint accepts no credential; loopback-only',
              $Pdb = $null)
        $o = [PSCustomObject]@{ name = $Name; enabled = $true; kind = 'native-sse'
            transport = $Transport; bind = '127.0.0.1'; port = 8770; path = '/sse'
            auth = $Auth; authExemptReason = $Reason }
        if ($null -ne $Pdb) { $o | Add-Member -NotePropertyName pdb -NotePropertyValue $Pdb }
        return $o
    }

    It 'accepts sse as a transport' {
        { Test-McpServerTransport -Config (Get-TestServerConfig @(Get-TestServer)) } |
            Should -Not -Throw
    }

    It 'still accepts the existing http transport unchanged' {
        # Every shipped server uses this; the new value must not narrow the old one.
        { Test-McpServerTransport -Config (Get-TestServerConfig @(
                    Get-TestServer -Transport 'http')) } | Should -Not -Throw
    }

    It 'rejects an unknown transport' {
        { Test-McpServerTransport -Config (Get-TestServerConfig @(
                    Get-TestServer -Transport 'grpc')) } | Should -Throw '*grpc*'
    }

    It 'rejects an unauthenticated server with no recorded reason' {
        # The exemption must be a decision, not an omission.
        { Test-McpServerTransport -Config (Get-TestServerConfig @(
                    Get-TestServer -Reason '')) } | Should -Throw '*authExemptReason*'
    }

    It 'accepts a pdb block naming a module' {
        $pdb = [PSCustomObject]@{ module = 'ntdll'; warmTables = @('publics') }
        { Test-McpServerTransport -Config (Get-TestServerConfig @(
                    Get-TestServer -Pdb $pdb)) } | Should -Not -Throw
    }

    It 'rejects a pdb block with no module' {
        $pdb = [PSCustomObject]@{ warmTables = @('publics') }
        { Test-McpServerTransport -Config (Get-TestServerConfig @(
                    Get-TestServer -Pdb $pdb)) } | Should -Throw '*module*'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Test-McpServerTransport` is not recognized.

- [ ] **Step 3: Implement it**

Add to `src/ReAgent.Config.psm1` above `Export-ModuleMember`, and add the name to that list.
Call it from `Test-ReAgentConfigSchema` beside the existing `Test-SkillPackSchema` and
`Test-AgentSchema` calls.

```powershell
$script:ValidTransport = @('stdio', 'http', 'sse')

function Test-McpServerTransport {
    <#
    .SYNOPSIS
        Validates transport, auth exemption and the optional pdb block.
    .DESCRIPTION
        'sse' joins the existing values rather than replacing them: pdbsql and
        ghidrasql serve MCP over SSE, every previously shipped server does not,
        and both must keep loading.

        An HTTP-family server carrying no token must name a reason. The
        exemption already exists for pyghidra-mcp (L10) and is reused rather
        than reinvented, so an unauthenticated server is always a recorded
        decision instead of an oversight.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-McpServerTransport -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    foreach ($s in @($Config.mcpServers)) {
        $transport = "$($s.transport)"
        if ($script:ValidTransport -notcontains $transport) {
            throw ("Server '$($s.name)' declares transport '$transport'. Valid: " +
                "[$($script:ValidTransport -join ', ')].")
        }
        if ($transport -ne 'stdio' -and "$($s.auth)" -eq 'none' -and
            -not "$($s.authExemptReason)".Trim()) {
            throw ("Server '$($s.name)' has transport '$transport' with auth 'none' and no " +
                'authExemptReason. An unauthenticated network transport must record why.')
        }
        if ($s.PSObject.Properties.Name -contains 'pdb' -and
            -not "$($s.pdb.module)".Trim()) {
            throw "Server '$($s.name)' has a pdb block with no 'module'."
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Config.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Config.psm1 tests/ReAgent.Config.Tests.ps1
git commit -m "Validate the sse transport and the pdb block at config load"
```

---

### Task 4: Resolve a PDB through the symbol-server tree (check Q1)

`C:\re\symbols` is a two-level symbol-server cache. The real file is
`…\ntdll.pdb\<GUID>\ntdll.pdb`. Passing `…\ntdll.pdb` — which looks like the file and is a
directory — fails inside `pdbsql` with `HRESULT 0x806D0005`, reported as "file not found or
inaccessible". That error names neither the directory nor the cause, so resolution and its
check belong in this repo.

**Files:**
- Modify: `src/ReAgent.Symbols.psm1`
- Test: `tests/ReAgent.Symbols.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Resolve-PdbPath -SymbolRoot <string> -Module <string>` → the full path to the newest
    matching `.pdb` **file**, or `$null` when the cache holds none.
  - `Test-PdbPathCheck -Server <object> -SymbolRoot <string>` → `[array]` of
    `{Check='Q1'; Message}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Symbols.Tests.ps1`:

```powershell
Describe 'Resolve-PdbPath' {
    BeforeAll {
        $script:Root = Join-Path ([IO.Path]::GetTempPath()) ("sym-" + [guid]::NewGuid())
        $guid = Join-Path $script:Root 'ntdll.pdb\1DF9DB46D55D6B869568C9F6E9287DE41'
        New-Item -ItemType Directory -Path $guid -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $guid 'ntdll.pdb') -Value 'fake' -Encoding Ascii
    }
    AfterAll { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'walks the GUID directory to the real file' {
        $p = Resolve-PdbPath -SymbolRoot $script:Root -Module 'ntdll'
        (Test-Path -LiteralPath $p -PathType Leaf) | Should -BeTrue
        $p | Should -BeLike '*1DF9DB46D55D6B869568C9F6E9287DE41\ntdll.pdb'
    }

    It 'never returns the container directory' {
        # The 0x806D0005 trap: '<root>\ntdll.pdb' exists and is a directory.
        $p = Resolve-PdbPath -SymbolRoot $script:Root -Module 'ntdll'
        $p | Should -Not -Be (Join-Path $script:Root 'ntdll.pdb')
    }

    It 'returns null for a module the cache has never warmed' {
        Resolve-PdbPath -SymbolRoot $script:Root -Module 'kernel32' | Should -BeNullOrEmpty
    }
}

Describe 'Test-PdbPathCheck (Q1)' {
    BeforeAll {
        $script:Root2 = Join-Path ([IO.Path]::GetTempPath()) ("sym-" + [guid]::NewGuid())
        $guid = Join-Path $script:Root2 'ntdll.pdb\AAAA1'
        New-Item -ItemType Directory -Path $guid -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $guid 'ntdll.pdb') -Value 'fake' -Encoding Ascii
    }
    AfterAll { Remove-Item -LiteralPath $script:Root2 -Recurse -Force -ErrorAction SilentlyContinue }

    It 'passes when the module resolves to a file' {
        $srv = [PSCustomObject]@{ name = 'pdbsql'
            pdb = [PSCustomObject]@{ module = 'ntdll' } }
        Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2 | Should -BeNullOrEmpty
    }

    It 'fails Q1 naming 0x806D0005 when the module is not in the cache' {
        $srv = [PSCustomObject]@{ name = 'pdbsql'
            pdb = [PSCustomObject]@{ module = 'nosuch' } }
        $f = Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2
        @($f).Count | Should -Be 1
        $f[0].Check | Should -Be 'Q1'
        $f[0].Message | Should -BeLike '*0x806D0005*'
    }

    It 'returns nothing for a server with no pdb block' {
        $srv = [PSCustomObject]@{ name = 'ghidrasql' }
        Test-PdbPathCheck -Server $srv -SymbolRoot $script:Root2 | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Symbols.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Resolve-PdbPath` is not recognized.

- [ ] **Step 3: Implement both functions**

Add to `src/ReAgent.Symbols.psm1` and to its `Export-ModuleMember` list:

```powershell
function Resolve-PdbPath {
    <#
    .SYNOPSIS
        Resolves a module name to its PDB file inside a symbol-server cache.
    .DESCRIPTION
        A symbol-server cache nests one level deeper than it looks:
        <root>\ntdll.pdb is a DIRECTORY holding <GUID>\ntdll.pdb. Handing the
        directory to a PDB reader fails with HRESULT 0x806D0005, reported as
        'file not found or inaccessible' - an error that names neither the
        directory nor the cause.

        The newest match wins when a cache holds several builds of one module,
        which is what a re-warmed cache looks like.
    .PARAMETER SymbolRoot
        The cache root, e.g. C:\re\symbols.
    .PARAMETER Module
        Module name without extension, e.g. 'ntdll'.
    .OUTPUTS
        [string] Full path to the .pdb file, or $null when absent.
    .EXAMPLE
        Resolve-PdbPath -SymbolRoot 'C:\re\symbols' -Module 'ntdll'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SymbolRoot,
        [Parameter(Mandatory)][string]$Module
    )

    $container = Join-Path $SymbolRoot "$Module.pdb"
    if (-not (Test-Path -LiteralPath $container -PathType Container)) { return $null }
    $match = Get-ChildItem -LiteralPath $container -Filter "$Module.pdb" -File -Recurse `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $match) { return $null }
    return $match.FullName
}

function Test-PdbPathCheck {
    <#
    .SYNOPSIS
        Runs check Q1: a configured pdb module must resolve to a real file.
    .DESCRIPTION
        Reads only the repo's config and the symbol cache, so it runs on every
        verification including -VerifyOnly on a host where nothing is installed.
        A server with no pdb block is not this check's business.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER SymbolRoot
        The symbol cache root.
    .OUTPUTS
        [array] Zero or one {Check='Q1'; Message} findings.
    .EXAMPLE
        Test-PdbPathCheck -Server $srv -SymbolRoot 'C:\re\symbols'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$SymbolRoot
    )

    if ($Server.PSObject.Properties.Name -notcontains 'pdb') { return @() }
    $module = "$($Server.pdb.module)"
    if (Resolve-PdbPath -SymbolRoot $SymbolRoot -Module $module) { return @() }
    return @([PSCustomObject]@{ Check = 'Q1'; Message = (
                "Server '$($Server.name)' names PDB module '$module', which does not " +
                "resolve to a file under '$SymbolRoot'. Passing the container directory " +
                'fails inside pdbsql with HRESULT 0x806D0005 ("file not found or ' +
                'inaccessible"). Warm the symbol cache for this module first.') })
}
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Symbols.Tests.ps1 -Output Detailed"
```
Expected: PASS, 6 new tests.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Symbols.psm1 tests/ReAgent.Symbols.Tests.ps1
git commit -m "Resolve PDBs through the symbol-server tree and check it"
```

---

### Task 5: The native-sse install kind

**Files:**
- Modify: `src/ReAgent.Servers.psm1`
- Test: `tests/ReAgent.Servers.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-PdbPath` (Task 4); `Get-VerifiedRelease`, `Write-ServerLauncher`,
  `Register-ServerScheduledTask`, `New-ServerResult` (all already exported).
- Produces:
  - `Get-NativeSseLaunchArgument -Server <object> -Config <object>` → `[string[]]` the launcher
    argument list.
  - `Install-NativeSseServer -Server <object> -Config <object> -Inventory <object>` →
    a server result object.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Servers.Tests.ps1`:

```powershell
Describe 'Get-NativeSseLaunchArgument' {
    BeforeAll {
        $script:Cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = 'C:\re'; stateRoot = 'C:\re\state'
                symbolCache = 'C:\re\symbols' }
        }
    }

    It 'puts the resolved PDB first and pins an explicit port' {
        # pdbsql defaults to a RANDOM port in 9000-9999. Ports are allocated
        # statically from config; a server must never pick its own.
        Mock Resolve-PdbPath { 'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb' }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770
            pdb = [PSCustomObject]@{ module = 'ntdll'; warmTables = @('publics', 'udts') } }
        $a = Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg
        $a[0] | Should -Be 'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        $a | Should -Contain '--mcp'
        $a | Should -Contain '8770'
        ($a -join ' ') | Should -BeLike '*--warm-tables publics,udts*'
    }

    It 'binds loopback explicitly' {
        Mock Resolve-PdbPath { 'C:\pdb\ntdll.pdb' }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770; bind = '127.0.0.1'
            pdb = [PSCustomObject]@{ module = 'ntdll' } }
        (Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg) |
            Should -Contain '127.0.0.1'
    }

    It 'passes --readonly for a server that declares it' {
        # ghidrasql: A3 cannot see a launcher flag, so Q0 checks this separately,
        # but the flag has to be here for Q0 to find.
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; port = 8771; bind = '127.0.0.1'
            readonly = $true; projectRoot = 'C:\re\mcp\ghidrasql\projects' }
        (Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg) |
            Should -Contain '--readonly'
    }

    It 'throws when a pdb server names a module the cache lacks' {
        Mock Resolve-PdbPath { $null }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770
            pdb = [PSCustomObject]@{ module = 'nosuch' } }
        { Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg } |
            Should -Throw '*nosuch*'
    }
}

Describe 'Install-McpServer dispatch' {
    It 'routes kind native-sse to its handler rather than reporting no handler' {
        Mock Install-NativeSseServer { New-ServerResult -Server $Server -Status 'installed' }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; enabled = $true; kind = 'native-sse' }
        $r = Install-McpServer -Server $srv -Config ([PSCustomObject]@{}) `
            -Inventory ([PSCustomObject]@{})
        $r.status | Should -Be 'installed'
        Assert-MockCalled Install-NativeSseServer -Times 1
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Servers.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Get-NativeSseLaunchArgument` is not recognized.

- [ ] **Step 3: Implement the argument builder and the installer**

Add to `src/ReAgent.Servers.psm1` and its `Export-ModuleMember`:

```powershell
function Get-NativeSseLaunchArgument {
    <#
    .SYNOPSIS
        Builds the launcher argument list for a native-sse server.
    .DESCRIPTION
        pdbsql binds ONE PDB per process, taken as a positional argument at
        launch, so the PDB belongs in the launcher rather than in a fan-out of
        one server per PDB (spec SQ7). It also defaults to a RANDOM port in
        9000-9999, so the port is always passed explicitly - ports are
        allocated statically from config.

        ghidrasql carries --readonly instead. That flag, not the tool
        classification, is what actually makes its single *_query tool
        read-only; check Q0 verifies it survived into the launcher.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER Config
        The parsed configuration object.
    .OUTPUTS
        [string[]] Arguments, in launcher order.
    .EXAMPLE
        Get-NativeSseLaunchArgument -Server $srv -Config $cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config
    )

    $args = @()
    if ($Server.PSObject.Properties.Name -contains 'pdb') {
        $root = $Config.paths.symbolCache
        $module = "$($Server.pdb.module)"
        $pdb = Resolve-PdbPath -SymbolRoot $root -Module $module
        if (-not $pdb) {
            throw ("Cannot launch '$($Server.name)': PDB module '$module' does not resolve " +
                "to a file under '$root'. Warm the symbol cache first.")
        }
        $args += $pdb
        if ($Server.pdb.PSObject.Properties.Name -contains 'warmTables') {
            $args += @('--warm-tables', (@($Server.pdb.warmTables) -join ','))
        }
    }
    if ($Server.PSObject.Properties.Name -contains 'readonly' -and $Server.readonly) {
        $args += '--readonly'
    }
    if ($Server.PSObject.Properties.Name -contains 'projectRoot') {
        $args += @('--project', "$($Server.projectRoot)")
    }
    $args += @('--mcp', "$($Server.port)")
    if ($Server.PSObject.Properties.Name -contains 'bind') {
        $args += @('--bind', "$($Server.bind)")
    }
    return $args
}

function Install-NativeSseServer {
    <#
    .SYNOPSIS
        Installs a pinned native binary that serves MCP over SSE.
    .DESCRIPTION
        Extracts a hash-verified release zip, writes the launcher only when its
        content differs (HANDOFF defect 7 - its timestamp drives the restart
        decision), and registers the logon Scheduled Task. Claude Code cannot
        spawn a long-running HTTP server, which is the same constraint that
        produced L10 for pyghidra-mcp.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        Host inventory from Get-HostInventory.
    .OUTPUTS
        [PSCustomObject] A server result from New-ServerResult.
    .EXAMPLE
        Install-NativeSseServer -Server $srv -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    $home = Join-Path (Join-Path $Config.paths.toolRoot 'mcp') $Server.name
    $zip = Get-VerifiedRelease -Server $Server -Config $Config
    if (-not (Test-Path -LiteralPath $home)) {
        New-Item -ItemType Directory -Path $home -Force | Out-Null
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $home, $true)

    $exe = Get-ChildItem -LiteralPath $home -Filter "$($Server.name).exe" -Recurse -File |
        Select-Object -First 1
    if ($null -eq $exe) {
        return New-ServerResult -Server $Server -Status 'failed' -Reason (
            "The release archive contained no $($Server.name).exe.")
    }

    $launcher = Join-Path $home "launch-$($Server.name).cmd"
    Write-ServerLauncher -Path $launcher -Executable $exe.FullName `
        -Arguments (Get-NativeSseLaunchArgument -Server $Server -Config $Config) | Out-Null
    Register-ServerScheduledTask -Server $Server -LauncherPath $launcher | Out-Null
    return New-ServerResult -Server $Server -Status 'installed'
}
```

Then add the dispatcher branch in `Install-McpServer`'s `switch ($Server.kind)`, immediately
before the `default` arm:

```powershell
            'native-sse' {
                return Install-NativeSseServer -Server $Server -Config $Config `
                    -Inventory $Inventory
            }
```

`src/ReAgent.Servers.psm1` is an existing file on `Z:` — patch it with a Python script.

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Servers.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ReAgent.Servers.psm1 tests/ReAgent.Servers.Tests.ps1
git commit -m "Add the native-sse install kind for the SQL-layer servers"
```

---

### Task 6: Probe by the configured transport, and add check Q0

**Files:**
- Modify: `src/ReAgent.Verify.psm1`
- Test: `tests/ReAgent.Verify.Tests.ps1`

**Interfaces:**
- Consumes: `Test-PdbPathCheck` (Task 4), `Invoke-McpProbe` (already exported).
- Produces:
  - `Test-ReadOnlyLaunchCheck -Server <object> -LauncherPath <string>` → `[array]` of
    `{Check='Q0'; Message}`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Verify.Tests.ps1`:

```powershell
Describe 'Test-HttpServerLive transport selection' {
    BeforeAll {
        $Script:SeenProbeArgs = @()
        Mock -CommandName Invoke-McpProbe -MockWith {
            $Script:SeenProbeArgs = $ProbeArgs
            return '{"ok": true, "toolCount": 2, "tools": ["pdbsql_query", "pdbsql_help"]}'
        } -ModuleName ReAgent.Verify
    }

    It 'passes --transport=sse for a server declaring sse' {
        $srv = [PSCustomObject]@{ name = 'pdbsql'; transport = 'sse'; bind = '127.0.0.1'
            port = 8770; path = '/sse'; auth = 'none' }
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = 'C:\re' } }
        Test-HttpServerLive -Server $srv -Config $cfg -PythonPath 'py.exe' | Out-Null
        ($Script:SeenProbeArgs -join ' ') | Should -BeLike '*--transport=sse*'
    }

    It 'still passes --transport=http for every existing server' {
        # Regression guard: sse must not become the default.
        $srv = [PSCustomObject]@{ name = 'pyghidra-mcp'; transport = 'http'
            bind = '127.0.0.1'; port = 8762; path = '/mcp'; auth = 'none' }
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = 'C:\re' } }
        Test-HttpServerLive -Server $srv -Config $cfg -PythonPath 'py.exe' | Out-Null
        ($Script:SeenProbeArgs -join ' ') | Should -BeLike '*--transport=http*'
    }
}

Describe 'Test-ReadOnlyLaunchCheck (Q0)' {
    BeforeAll {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("q0-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    }
    AfterAll { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'passes when the launcher carries --readonly' {
        $p = Join-Path $script:Dir 'ok.cmd'
        Set-Content -LiteralPath $p -Value '"C:\ghidrasql.exe" --readonly --mcp 8771'
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; readonly = $true }
        Test-ReadOnlyLaunchCheck -Server $srv -LauncherPath $p | Should -BeNullOrEmpty
    }

    It 'fails Q0 when --readonly was stripped from the launcher' {
        # A3 judges the derived grant and cannot see a launcher flag. Without
        # --readonly, ghidrasql_query writes to the program database while still
        # classified 'read' - the gate would pass over a real write grant.
        $p = Join-Path $script:Dir 'bad.cmd'
        Set-Content -LiteralPath $p -Value '"C:\ghidrasql.exe" --mcp 8771'
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; readonly = $true }
        $f = Test-ReadOnlyLaunchCheck -Server $srv -LauncherPath $p
        @($f).Count | Should -Be 1
        $f[0].Check | Should -Be 'Q0'
        $f[0].Message | Should -BeLike '*--readonly*'
    }

    It 'fails Q0 when the launcher does not exist yet' {
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; readonly = $true }
        $f = Test-ReadOnlyLaunchCheck -Server $srv `
            -LauncherPath (Join-Path $script:Dir 'missing.cmd')
        $f[0].Check | Should -Be 'Q0'
    }

    It 'returns nothing for a server that does not declare readonly' {
        $p = Join-Path $script:Dir 'ok.cmd'
        $srv = [PSCustomObject]@{ name = 'pdbsql' }
        Test-ReadOnlyLaunchCheck -Server $srv -LauncherPath $p | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Verify.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Test-ReadOnlyLaunchCheck` is not recognized, and the transport assertion
fails because `--transport=http` is hard-coded.

- [ ] **Step 3: Make the transport data-driven**

In `src/ReAgent.Verify.psm1`, inside `Test-HttpServerLive`, replace the hard-coded
`'--transport=http'` probe argument with a value read from the server entry, defaulting to
`http` so every existing config is unchanged:

```powershell
    $transport = 'http'
    if ($Server.PSObject.Properties.Name -contains 'transport' -and
        "$($Server.transport)" -eq 'sse') { $transport = 'sse' }
```

and use `"--transport=$transport"` where `'--transport=http'` appeared.

- [ ] **Step 4: Add check Q0**

Add to `src/ReAgent.Verify.psm1` and its `Export-ModuleMember`:

```powershell
function Test-ReadOnlyLaunchCheck {
    <#
    .SYNOPSIS
        Runs check Q0: a read-only server's launcher must carry --readonly.
    .DESCRIPTION
        The SQL layer collapses many operations into one tool, but the agent
        gate classifies per tool. ghidrasql_query reads or writes depending on
        the text of the SQL, and A3 cannot see the SQL. What makes the tool
        genuinely read-only is the server flag, so the flag is what gets
        checked - the classification is a consequence of it, not a control.

        Sub-classifying by parsing SQL would be a denylist, and a denylist gets
        bypassed. See spec section 7.3.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER LauncherPath
        The generated launcher for that server.
    .OUTPUTS
        [array] Zero or one {Check='Q0'; Message} findings.
    .EXAMPLE
        Test-ReadOnlyLaunchCheck -Server $srv -LauncherPath $p
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$LauncherPath
    )

    if ($Server.PSObject.Properties.Name -notcontains 'readonly') { return @() }
    if (-not $Server.readonly) { return @() }

    $reason = ''
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        $reason = "its launcher '$LauncherPath' does not exist"
    } else {
        $text = Get-Content -LiteralPath $LauncherPath -Raw
        if ($text -notmatch '(?m)--readonly\b') {
            $reason = "its launcher does not pass --readonly"
        }
    }
    if (-not $reason) { return @() }
    return @([PSCustomObject]@{ Check = 'Q0'; Message = (
                "Server '$($Server.name)' is declared read-only but $reason. Its " +
                '*_query tool is classified read on the strength of that flag; without ' +
                'it the tool can write and the agent gate will not notice.') })
}
```

- [ ] **Step 5: Wire Q0 and Q1 into verification**

In `Invoke-Verification`, after the existing skills and agents checks, add a `sql` check group
that runs `Test-ReadOnlyLaunchCheck` and `Test-PdbPathCheck` over every enabled `native-sse`
server and reports through `New-CheckResult`. Both read only the repo and the generated
launchers, so they run on every verification, including `-VerifyOnly` on a host where nothing
is installed.

- [ ] **Step 6: Run the full suite**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; $r = Invoke-Pester -Path tests/ -Output None -PassThru; Write-Host \"PASSED=$($r.PassedCount) FAILED=$($r.FailedCount)\""
```
Expected: `FAILED=0`.

- [ ] **Step 7: Commit**

```bash
git add src/ReAgent.Verify.psm1 tests/ReAgent.Verify.Tests.ps1
git commit -m "Probe by configured transport and check the read-only launch"
```

---

### Task 7: Declare pdbsql, and prove it live

**Files:**
- Modify: `re-agent.config.json`
- Modify: `data/tool-catalog.json`
- Test: `tests/Integration.Tests.ps1`

**Interfaces:**
- Consumes: everything from Tasks 2–6.

- [ ] **Step 1: Add the server entry**

Patch `re-agent.config.json` with a Python script. Add to `mcpServers`:

```json
{ "name": "pdbsql", "enabled": true, "kind": "native-sse",
  "source": { "type": "github-release", "repo": "0xeb/pdbsql", "pin": "v0.0.7",
              "sha256": { "pdbsql-windows-x64.zip":
                          "bdfc1328397d4329ed3a2d8dc647e16e77709b077efb8075b1fd740fbe03a8e8" } },
  "transport": "sse", "bind": "127.0.0.1", "port": 8770, "path": "/sse",
  "auth": "none",
  "authExemptReason": "upstream --mcp endpoint accepts no credential; --token covers only the REST mode; loopback-only, Profile A",
  "scheduledTask": "ReLab-pdbsql", "requiresHostApp": false, "verifyTier": "unattended",
  "pdb": { "module": "ntdll", "warmTables": ["functions", "publics", "udts"] },
  "verify": { "tool": "pdbsql_query",
              "args": { "query": "SELECT COUNT(*) AS n FROM publics" },
              "expect": "\"n\":\\s*[1-9]" } }
```

- [ ] **Step 2: Add the catalog entry and classification**

Patch `data/tool-catalog.json`, adding under `servers`:

```json
"pdbsql": {
  "pin": "v0.0.7",
  "toolCount": 2,
  "tools": ["pdbsql_help", "pdbsql_query"],
  "classification": {
    "classifiedBy": "david",
    "classifiedAt": "2026-09-09",
    "classifiedTools": ["pdbsql_help", "pdbsql_query"],
    "write": [],
    "destructive": []
  }
}
```

Rationale for the commit message: a PDB is a read-only artifact, so `pdbsql_query` is `read`.
Its one caveat is `runtime_settings`, which accepts `UPDATE` — that mutates query timeouts
inside the server process, reaches no analysis data, and is recorded in spec §12 gap 2 rather
than classified `write`, which would cost the verifier its only deterministic grounding source
and buy nothing.

- [ ] **Step 3: Grant pdbsql to the verifier**

In `re-agent.config.json`, add `"pdbsql"` to the `verifier` agent's `targetServers`, and to
`static-analyst`'s.

- [ ] **Step 4: Write the integration tests**

Append to `tests/Integration.Tests.ps1`:

```powershell
Describe 'the SQL layer, stage 1' {
    BeforeAll {
        $script:Cfg = Get-ReAgentConfig -Path (Join-Path $PSScriptRoot '../re-agent.config.json')
        $script:Cat = Get-ToolCatalog
    }

    It 'declares pdbsql as an unattended sse server with a recorded auth exemption' {
        $s = @($script:Cfg.mcpServers | Where-Object { $_.name -eq 'pdbsql' })[0]
        $s.transport | Should -Be 'sse'
        $s.verifyTier | Should -Be 'unattended'
        "$($s.authExemptReason)".Trim() | Should -Not -BeNullOrEmpty
    }

    It 'classifies every pdbsql tool, so A4 passes' {
        Test-AgentClassificationCheck -Catalog $script:Cat -Server 'pdbsql' |
            Should -BeNullOrEmpty
    }

    It 'grants the verifier pdbsql and still passes A0-A4' {
        $v = @($script:Cfg.agents | Where-Object { $_.name -eq 'verifier' })[0]
        $v.targetServers | Should -Contain 'pdbsql'
        Invoke-AgentGate -Agent $v -Catalog $script:Cat `
            -Frontmatter @{ name = 'verifier' } -FileBaseName 'verifier' |
            Should -BeNullOrEmpty
    }

    It 'grants the verifier no pdbsql tool classified write or destructive' {
        $v = @($script:Cfg.agents | Where-Object { $_.name -eq 'verifier' })[0]
        $g = Get-AgentToolGrant -Agent $v -Catalog $script:Cat
        $c = Get-ToolClassification -Catalog $script:Cat -Server 'pdbsql'
        foreach ($t in @($g.Tools | Where-Object { $_ -like 'mcp__pdbsql__*' })) {
            $bare = $t -replace '^mcp__pdbsql__', ''
            Get-ToolLevel -Classification $c -Tool $bare | Should -Be 'read'
        }
    }
}
```

- [ ] **Step 5: Run the full suite**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; $r = Invoke-Pester -Path tests/ -Output None -PassThru; Write-Host \"PASSED=$($r.PassedCount) FAILED=$($r.FailedCount)\"; Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"
```
Expected: `FAILED=0` and no analyzer output.

- [ ] **Step 6: LIVE — install and prove a real tool call**

This is definition-of-done item 1, and the only check `MVP.md` says matters.

Run:
```bash
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -Phases 3"
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -VerifyOnly"
```
Expected: `pdbsql` reports `pass` with a non-zero `publics` count.

Then confirm idempotency — definition-of-done item 3:

```bash
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -Phases 3"
```
Expected: no launcher rewrite, no restart line, `already current`.

- [ ] **Step 7: Commit**

```bash
git add re-agent.config.json data/tool-catalog.json tests/Integration.Tests.ps1
git commit -m "Declare pdbsql and grant it to the verifier"
```

---

### Task 8: The ghidrasql server — STAGE 2, requires Task 1 to have passed

**Do not start this task if Task 1's gate did not record a pass.**

**Files:**
- Modify: `re-agent.config.json`
- Modify: `src/ReAgent.Servers.psm1`
- Test: `tests/ReAgent.Servers.Tests.ps1`

**Interfaces:**
- Consumes: `Get-NativeSseLaunchArgument`, `Install-NativeSseServer` (Task 5);
  `Test-ReadOnlyLaunchCheck` (Task 6); the built extension zip from Task 1.
- Produces: `Install-LibGhidraExtension -ExtensionZip <string> -GhidraRoot <string>` → `$true`
  when it wrote the extension, `$false` when it was already current.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ReAgent.Servers.Tests.ps1`:

```powershell
Describe 'Install-LibGhidraExtension' {
    BeforeAll {
        $script:GRoot = Join-Path ([IO.Path]::GetTempPath()) ("gh-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:GRoot 'Ghidra\Extensions') `
            -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stage = Join-Path ([IO.Path]::GetTempPath()) ("st-" + [guid]::NewGuid())
        $inner = Join-Path $stage 'LibGhidraHost'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $inner 'extension.properties') `
            -Value "name=LibGhidraHost`nversion=12.1.2"
        $script:Zip = "$stage.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $script:Zip)
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    AfterAll {
        Remove-Item -LiteralPath $script:GRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Zip -Force -ErrorAction SilentlyContinue
    }

    It 'writes the extension into the Ghidra tree on a first install' {
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot |
            Should -BeTrue
        Test-Path (Join-Path $script:GRoot `
                'Ghidra\Extensions\LibGhidraHost\extension.properties') | Should -BeTrue
    }

    It 'reports no change on a second run, so a steady-state run touches nothing' {
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot | Out-Null
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot |
            Should -BeFalse
    }

    It 'refuses an extension stamped for a different Ghidra than the host runs' {
        # The Task 1 gate again, enforced at install time: a stamp mismatch here
        # means someone substituted a prebuilt release zip for the built one.
        Mock Get-GhidraVersion { '12.1.3' }
        { Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot } |
            Should -Throw '*12.1.2*'
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Servers.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Install-LibGhidraExtension` is not recognized.

- [ ] **Step 3: Implement it**

Add to `src/ReAgent.Servers.psm1` and its `Export-ModuleMember`:

```powershell
function Install-LibGhidraExtension {
    <#
    .SYNOPSIS
        Installs the built LibGhidraHost extension into a Ghidra distribution.
    .DESCRIPTION
        The extension MUST be the one built against this host (spec SQ6): a
        prebuilt release zip declares whatever Ghidra its author had, and
        Ghidra matches that string exactly. The version is re-asserted here as
        well as at build time, because the two happen at different moments and
        a release zip could be substituted between them.

        Writing only on change keeps a steady-state run from touching the
        Ghidra tree that pyghidra-mcp also runs against.
    .PARAMETER ExtensionZip
        The zip produced by tools\Build-LibGhidraExtension.ps1.
    .PARAMETER GhidraRoot
        The Ghidra distribution root.
    .OUTPUTS
        [bool] True when the extension was written, false when already current.
    .EXAMPLE
        Install-LibGhidraExtension -ExtensionZip $zip -GhidraRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExtensionZip,
        [Parameter(Mandatory)][string]$GhidraRoot
    )

    $expected = Get-GhidraVersion -GhidraRoot $GhidraRoot
    . "$PSScriptRoot\..\tools\Build-LibGhidraExtension.ps1" -DotSourceOnly
    Assert-StampedExtensionVersion -ZipPath $ExtensionZip -ExpectedVersion $expected | Out-Null

    $target = Join-Path (Join-Path $GhidraRoot 'Ghidra\Extensions') 'LibGhidraHost'
    $marker = Join-Path $target 'extension.properties'
    $hashFile = Join-Path $target '.re-agent-source-sha256'
    $sourceHash = (Get-FileHash -LiteralPath $ExtensionZip -Algorithm SHA256).Hash
    if ((Test-Path -LiteralPath $marker) -and (Test-Path -LiteralPath $hashFile) -and
        (Get-Content -LiteralPath $hashFile -Raw).Trim() -eq $sourceHash) {
        return $false
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory(
        $ExtensionZip, (Join-Path $GhidraRoot 'Ghidra\Extensions'), $true)
    Set-Content -LiteralPath $hashFile -Value $sourceHash -Encoding Ascii
    return $true
}
```

- [ ] **Step 4: Add the ghidrasql server entry**

Patch `re-agent.config.json`, adding to `mcpServers`:

```json
{ "name": "ghidrasql", "enabled": true, "kind": "native-sse",
  "source": { "type": "github-release", "repo": "0xeb/ghidrasql", "pin": "v0.0.6",
              "sha256": { "ghidrasql-cli-windows-v0.0.6.zip":
                          "d646e49f1373846decdbc869722e3861b45cb84714fcd1a439f346c9816caff5" },
              "libghidra": { "repo": "0xeb/libghidra", "pin": "v0.0.7" } },
  "transport": "sse", "bind": "127.0.0.1", "port": 8771, "path": "/sse",
  "auth": "none",
  "authExemptReason": "upstream --mcp endpoint accepts no credential; loopback-only, Profile A",
  "scheduledTask": "ReLab-ghidrasql", "requiresHostApp": false, "verifyTier": "unattended",
  "readonly": true,
  "projectRoot": "C:\\re\\mcp\\ghidrasql\\projects",
  "verify": { "tool": "ghidrasql_query",
              "args": { "query": "SELECT COUNT(*) AS n FROM funcs" },
              "expect": "\"n\":\\s*[1-9]" } }
```

`projectRoot` is deliberately **not** `pyghidra-mcp`'s project. They share the Ghidra
distribution but never a project, so the `LockException` of HANDOFF defect 5 cannot recur.

- [ ] **Step 5: Run to verify they pass**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ReAgent.Servers.Tests.ps1 -Output Detailed"
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ReAgent.Servers.psm1 tests/ReAgent.Servers.Tests.ps1 re-agent.config.json
git commit -m "Install the built LibGhidraHost extension and declare ghidrasql"
```

---

### Task 9: Classify ghidrasql, grant it, and prove it live — STAGE 2

**Do not start this task if Task 1's gate did not record a pass.**

**Files:**
- Modify: `data/tool-catalog.json`
- Modify: `re-agent.config.json`
- Test: `tests/Integration.Tests.ps1`

**Interfaces:**
- Consumes: everything from Tasks 1–8.

- [ ] **Step 1: Add the catalog entry and classification**

Patch `data/tool-catalog.json`, adding under `servers`:

```json
"ghidrasql": {
  "pin": "v0.0.6",
  "toolCount": 2,
  "tools": ["ghidrasql_help", "ghidrasql_query"],
  "classification": {
    "classifiedBy": "david",
    "classifiedAt": "2026-09-09",
    "classifiedTools": ["ghidrasql_help", "ghidrasql_query"],
    "write": [],
    "destructive": []
  }
}
```

Record in the commit message: `ghidrasql_query` is classified `read` **only because the server
runs `--readonly`**. Check Q0 enforces the flag; the classification is a consequence of it, not
a control. Spec §7.3 and §12 gap 3.

- [ ] **Step 2: Grant ghidrasql to the static analyst**

Add `"ghidrasql"` to `static-analyst`'s `targetServers`. **Do not grant it to the verifier** —
the verifier's grounding comes from `pdbsql`, which needs no flag to be read-only.

- [ ] **Step 3: Write the integration tests**

Append to `tests/Integration.Tests.ps1`:

```powershell
Describe 'the SQL layer, stage 2' {
    BeforeAll {
        $script:Cfg2 = Get-ReAgentConfig -Path (Join-Path $PSScriptRoot '../re-agent.config.json')
        $script:Cat2 = Get-ToolCatalog
    }

    It 'declares ghidrasql read-only' {
        $s = @($script:Cfg2.mcpServers | Where-Object { $_.name -eq 'ghidrasql' })[0]
        $s.readonly | Should -BeTrue
    }

    It 'keeps ghidrasql off the verifier, whose read-only-ness rests on no flag' {
        $v = @($script:Cfg2.agents | Where-Object { $_.name -eq 'verifier' })[0]
        $v.targetServers | Should -Not -Contain 'ghidrasql'
    }

    It 'gives ghidrasql its own project root, never pyghidra-mcp s' {
        # HANDOFF defect 5 was a Ghidra project LockException. Two consumers of
        # one distribution is fine; two consumers of one project is not.
        $s = @($script:Cfg2.mcpServers | Where-Object { $_.name -eq 'ghidrasql' })[0]
        $pg = @($script:Cfg2.mcpServers | Where-Object { $_.name -eq 'pyghidra-mcp' })[0]
        $s.projectRoot | Should -Not -Be $pg.projectPath
    }

    It 'passes A0-A4 for the static analyst with ghidrasql added' {
        $a = @($script:Cfg2.agents | Where-Object { $_.name -eq 'static-analyst' })[0]
        Invoke-AgentGate -Agent $a -Catalog $script:Cat2 `
            -Frontmatter @{ name = 'static-analyst' } -FileBaseName 'static-analyst' |
            Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 4: Run the full suite and the analyzer**

Run:
```bash
powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; $r = Invoke-Pester -Path tests/ -Output None -PassThru; Write-Host \"PASSED=$($r.PassedCount) FAILED=$($r.FailedCount)\"; Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"
```
Expected: `FAILED=0` and no analyzer output.

- [ ] **Step 5: LIVE — prove a real tool call**

Definition-of-done item 2.

Run:
```bash
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -Phases 3"
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -VerifyOnly"
```
Expected: `ghidrasql` reports `pass` with a non-zero `funcs` count, and `pyghidra-mcp` still
reports `pass` — the two share a Ghidra distribution and must both work.

- [ ] **Step 6: Verify Q0 catches a stripped flag, then restore**

The red-green check for the control this whole task rests on.

Run:
```bash
powershell.exe -NoProfile -Command "(Get-Content C:\re\mcp\ghidrasql\launch-ghidrasql.cmd) -replace ' --readonly','' | Set-Content C:\re\mcp\ghidrasql\launch-ghidrasql.cmd"
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -VerifyOnly"
```
Expected: **Q0 fails**, naming `--readonly`.

Then restore and confirm it passes again:
```bash
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -Phases 3"
powershell.exe -NoProfile -Command ".\Install-REAgent.ps1 -VerifyOnly"
```
Expected: Q0 passes.

- [ ] **Step 7: Commit**

```bash
git add data/tool-catalog.json re-agent.config.json tests/Integration.Tests.ps1
git commit -m "Classify ghidrasql read-only and grant it to the static analyst"
```

---

## Spec coverage

| Spec section | Task |
|---|---|
| §1.3 definition of done, items 1–6 | 7 (1, 3, 4), 9 (2), 7 and 9 (5, 6) |
| SQ1 staging | Task 1's gate; Tasks 8–9 marked stage 2 |
| SQ2 the `native-sse` kind | 5 |
| SQ3 scheduled task | 5 |
| SQ4 unauthenticated, recorded | 3 (schema), 7 and 8 (`authExemptReason`) |
| SQ5 read-only | 6 (Q0), 8 (`readonly: true`), 9 (classification) |
| SQ6 extension built, never installed from a release zip | 1, 8 |
| SQ7 PDB as a launcher parameter | 4, 5 |
| §3.2 the SSE transport gap | 2 |
| §3.4 the `0x806D0005` path trap | 4 |
| §3.6 the version lock | **1 — the gate** |
| §4 ports and disk layout | 5, 7, 8 |
| §5.1 `native-sse` install | 5 |
| §5.2 the vendor-time build | 1 |
| §6 config schema | 3 |
| §7.1–7.2 catalog and classification | 7, 9 |
| §7.3 the classification tension | 6 (Q0), 9 |
| §7.4 grants | 7 (verifier), 9 (static-analyst) |
| §9 manifest and idempotency | 5 (`Write-FileIfChanged`), 7 step 6 |
| §10 testing, all four negative tests | 3 (#1), 6 and 9 step 6 (#2), 4 (#3), 7 and 9 (#4) |
| §12 gap 4, the unproven build | **1 — closed or recorded by the gate** |

**Not covered by any task, deliberately:** spec §8 (the `sql-query` skill and the upstream
`0xeb` skill packs). It depends on a licence review of
`LicenseRef-Human-Origin-Source-1.0`, which is a human decision, and the spec lists the packs
as candidates rather than scheduled work. It belongs in its own plan once that review happens.

## Deviations from the spec

1. **No `authExempt` boolean.** Spec §6's config sketch invented one. The schema already
   expresses this with `auth: "none"` plus `authExemptReason`, which `pyghidra-mcp` uses today.
   Adding a second mechanism for the same fact would leave two places to check. The spec's
   intent — that an unauthenticated server records why — is enforced in Task 3 against the
   existing fields.

2. **`source` block shape.** Spec §6's sketch used `source.release` plus a flat
   `source.sha256` string and an `asset` field. `Get-VerifiedRelease` (`ReAgent.Servers.psm1`)
   reads `source.pin` and `source.sha256` as an **asset-name to hash map** — the shape
   `x64dbg-x64`, `x64dbg-x32` and `ghidramcp` already use. The plan uses the real shape.
3. **The symbol cache root is `paths.symbolCache`**, not `symbols.cacheRoot`. The `symbols`
   block holds only `enabled`, `server` and `prewarm`.

## A note for the reviewer

Task 1 is the whole risk of this plan. Everything in stage 1 is measured working; everything in
stage 2 rests on an argument about token substitution that spec §3.6 makes from source and
Ghidra's own build script, and that nobody has executed. It is deliberately first, and
deliberately produces a committed, tested artifact either way — so a failed gate still leaves
`tools/Build-LibGhidraExtension.ps1` in the tree, with tests, ready for the day upstream ships
an extension targeting this host's Ghidra.

If the gate fails, resist the temptation to hand-edit `extension.properties` to say `12.1.2`.
That bypasses Ghidra's version check without proving the Java API matches, which converts a
loud build failure into a quiet runtime one — and this repo already carries a server disabled
for exactly the version-mismatch reason.
