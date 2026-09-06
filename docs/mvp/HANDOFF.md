# Handoff — Install-REAgent

**State as of 2026-09-06.** Read this first, then `MVP_FINDINGS.md`, then `MVP_SPEC.md`.

Branch `main` at merge commit `abbad02` — `feat/install-re-agent` (25 commits) merged `--no-ff`.
There is no remote and no `master`. The working tree carries uncommitted work: four defect fixes and
the tier-2 `verify` blocks, described below.

**314 Pester tests passing, zero PSScriptAnalyzer findings.**

---

## Read these, in this order

| File | Why |
|---|---|
| `MVP_FINDINGS.md` | **Measured host truth.** Overrides everything else on conflict. Resolves O1–O7 and records nine deviations from the original spec. |
| `MVP_SPEC.md` | The build spec, amended to match findings. |
| `MVP_PLAN.md` | Task-by-task plan. **Read "Corrections found while implementing"** — four bugs in its own code blocks, now fixed. |
| `MVP.md` | Scope, locked decisions (L1–L11), log. |

---

## Verify the state before changing anything

```powershell
cd Z:\REVERSING_AGENT
Import-Module Pester -MinimumVersion 5.5.0
Invoke-Pester -Path tests/ -Output Normal          # expect 314 passed, 0 failed
Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse   # expect no output
```

If Pester or PSScriptAnalyzer are missing, install them — but the obvious command fails on this box.
See `MVP_PLAN.md` Task 1 Step 1 for the NuGet bootstrap that makes it work.

Then, against the live host, with x64dbg / x32dbg and Binary Ninja open on a binary:

```powershell
.\Install-REAgent.ps1 -VerifyOnly -Attended         # no elevation needed except the manifest write
```

---

## What is done

All 16 tasks are implemented: 11 modules under `src/`, the `Install-REAgent.ps1` entry point,
`tools/mcp_probe.py`, `templates/CLAUDE.md.template`, and `re-agent.config.json` with real pins.

### The elevated end-to-end run happened (2026-09-05 19:47)

| Artifact | Contents |
|---|---|
| `C:\re\agent\.mcp.json` | All five enabled servers, loopback URLs, bearer headers |
| `C:\re\agent\.claude\settings.json` | Generated |
| `C:\re\agent\CLAUDE.md` | The operating contract |
| `C:\ProgramData\re-lab\manifest.json` | From that run |
| `C:\ProgramData\re-lab\install.log` | Full transcript |

The trust prompt has been accepted — the ⏸ Pending risk from O1 is settled. The x64dbg SHA-256 is
pinned for real (`1763b3c4…` for `x64dbg-MCP-Server-v1.3.zip`, both arch entries), so
trust-on-first-use is closed.

`GhidraMCP-release-1-4.zip` is still `PIN-ME`, and that is fine: `ghidramcp` is `"enabled": false`,
so `Get-VerifiedRelease` never sees it. It needs a hash only if someone enables it — and note the
1.4-targets-Ghidra-11.3.2 vs. host-runs-12.1.2 problem before bothering.

### Verification passes — 8 pass, 0 fail, 1 not-testable

`-VerifyOnly -Attended`, **unelevated, all six phases clean including the manifest**, 2026-09-06
08:53, with x64dbg, x32dbg and Binary Ninja all open on a binary:

| Check | Result |
|---|---|
| `claude --version` | pass — 2.1.263 |
| `claude mcp list` | pass |
| generated config | pass |
| `x64dbg-x64` live call | **pass** |
| `x64dbg-x32` live call | **pass** — 80 tools, `GetDebugState` answered |
| `binaryninja` live call | **pass** — 75 tools, `bn_binary_view_list` answered |
| `pyghidra-mcp` live call | **pass** — decompiled `entry` in `/winver.exe-e678d1` |
| `mcp-windbg` live call | **pass** — `ntdll listed with symbols resolved` |
| `ghidramcp` live call | not-testable — disabled in config, by design |

**Every enabled server answers a real tool call.** That is item 3 of the definition of done, the one
`MVP.md` calls the only one that matters.

### x64dbg's `mcp_config.json` path — RESOLVED

**It is written beside `x64dbg.exe`, in the release directory, not the plugins directory.** Measured:

```
C:\tools\x64dbg\release\x64\mcp_config.json    Port 9094, AuthToken c79dc75a…
C:\tools\x64dbg\release\x32\mcp_config.json    Port 9095, AuthToken f311c3c2…
C:\tools\x64dbg\release\{x64,x32}\plugins\     no mcp_config.json — only the .dp64/.dp32
```

The plugin honoured the pre-seeded file: the live server authenticates with exactly the token the
installer generated. `Write-X64dbgPreseed` and `Get-X64dbgConfigPath` are correct. **Do not reorder
them.**

### L11 (two x64dbg servers) is proven on the x32 side

`x64dbg-x32` on :9095 answered a real tool call with its own pre-seeded token, from x32dbg. The
compiled-in-port model holds. `x64dbg-x64` on :9094 was proven by hand earlier the same day, but has
not yet passed inside a verification run — open item 3.

### mcp-windbg's tool arguments — CONFIRMED

`open_cdb_dump{dump_path}` then `run_cdb_command{session_id, command}` is right. The check passes
against the dump Phase 3 creates and reports `ntdll listed with symbols resolved`, which also proves
Phase 2's symbol path works. The VERIFY note in `Test-WindbgLive` can come out.

### Tier-2 tool names — discovered live and wired in

| Server | Tools advertised | `verify` entry in `re-agent.config.json` |
|---|---|---|
| `x64dbg-x64` / `-x32` | 80 | `GetDebugState`, no args, expect `isDebugging:\s*true` |
| `binaryninja` | 75 (`bn_*`) | `bn_binary_view_list`, no args, expect `count:\s*[1-9]` |

`Test-HttpServerLive` reads these as data, so both went live with no code change.

### Four defects found and fixed on 2026-09-06

1. **`-VerifyOnly` produced a report of pure false negatives.** It ran phases 5–6 only, so
   `$context.Inventory` and `$context.ServerResults` were both empty: every server came back
   `not-testable — "Not installed on this host."`, `claude --version` came back `fail`, and the run
   ended throwing `Cannot bind argument to parameter 'Inventory' because it is null`.
   - `Select-Phase` (Common) now owns phase selection and keeps phase 0 under `-VerifyOnly`.
   - `Get-RecordedServerResult` (Manifest) replays the last run's server states out of
     `manifest.json`, rebuilding mcp-windbg's launch command through the new
     `Get-WindbgLaunchCommand` so the stdio probe can actually start it. With no manifest it returns
     nothing and says so.
   - `Invoke-Verification` now separates *unknown* from *not installed*: no record means "no manifest
     entry for it", not a claim about the host.
   - `Test-Preflight -VerifyOnly` drops the blockers that only installing needs — elevation, a VM,
     and egress. Claude Code's absence still blocks.
   - `Get-PreflightWarning` accepts a null inventory instead of throwing.

2. **`$PSScriptRoot` was empty in the `-ConfigPath` parameter default**, so a plain
   `.\Install-REAgent.ps1` died with `Config file not found at '\re-agent.config.json'`. Root cause:
   **`[CmdletBinding()]` on a script.** Bisected on this host, and it is not an SMB or drive
   artefact — an identical script without the attribute resolves the default correctly on both `C:`
   and `Z:`. Fixed by resolving the default in the body, where `$PSScriptRoot` is populated.

3. **PowerShell 5.1 strips double quotes out of a native command's arguments**, so
   `--calls=[{"tool":"x"}]` reached the probe as `--calls=[{tool:x}]`. Every check that sent a call
   sequence died on `JSONDecodeError: Expecting property name enclosed in double quotes: line 1
   column 3 (char 2)` — which `Test-HttpServerLive` then reported as *"Could not reach"*, blaming a
   healthy server. This is what the 2026-09-05 report's mcp-windbg failure actually was.
   `mcp_probe.py` gained `--calls-file`, and `Invoke-McpProbe` gained a `-Calls` parameter that
   writes the JSON to a temp file and deletes it afterwards. Nothing passes JSON on a command line
   any more.

4. **The pyghidra check passed on a failed decompilation.** `decompile_function` answers a *failed*
   decompilation with a successful tool call carrying `"code": ""` and an `error` field, and the old
   `-notmatch '\{|\('` heuristic matched the JSON envelope's own braces. It reported
   `pass … (174 chars)` on `Function or symbol 'entry' not found.` — the connected-but-broken case
   this suite exists to catch. It now parses the envelope and requires C.

---

## Two more defects, found and fixed on 2026-09-06

5. **A rewritten launcher never reached the running server.**
   `Register-ServerScheduledTask` compares the task's *action* — the launcher path, which never
   changes — so it logged `already current` and nothing restarted. pyghidra-mcp had been serving an
   empty project since 2026-09-05: the process started at 19:04:26 and the launcher naming
   `winver.exe` was written at 19:47:57. The positional-import path was never at fault; upstream's
   `init_pyghidra_context` calls `import_binaries(bin_paths)` exactly as expected.

   `Test-ServerRestartNeeded` now compares the task's `LastRunTime` against the launcher's
   `LastWriteTime`, and `Restart-StaleServerTask` acts on it. **`Stop-ScheduledTask` alone was not
   enough:** it only reaches instances the task started this session, so the orphan from the previous
   logon kept the Ghidra project locked and the replacement died with `LockException: Unable to lock
   project`. The restart therefore also stops the server by executable path, through the
   `Get-ProcessIdByPath` / `Stop-ProcessByPath` / `Stop-ProcessById` seams.

   Confirmed on the host: after the restart the project holds both `/GoogleUpdate.exe-4dd864` and
   `/winver.exe-e678d1`, analysis complete.

6. **The pyghidra check reported on whatever was imported first.** It took `programs[0]`, so an
   analyst's own import decided what the installer's verification asserted. It now prefers the
   configured `testBinary`, falling back to the first program when that binary is absent.

---

## Two regressions from the restart fix, found and fixed the same day

The restart in defect 5 was right in principle and wrong twice in practice. Both were caught by an
elevated run at 08:50, whose report came back with `claude mcp list` failed and pyghidra-mcp
unreachable — on a host where both had passed minutes earlier.

7. **It restarted the server on every run.** `Write-ServerLauncher` rewrote the launcher
   unconditionally — it is derived state — so its `LastWriteTime` was always newer than the task's
   `LastRunTime`, and the freshly added staleness check fired every time. The file is now written
   only when its content differs. Its timestamp is not derived state any more: the restart decision
   reads it.

8. **Verification probed a server the installer had just restarted.** Phase 3 stopped and started
   pyghidra-mcp; phase 5 probed it eight seconds later, got `ConnectError`, and reported it
   unreachable — which also failed `claude mcp list`, since the server was genuinely down at that
   moment. pyghidra-mcp imports and analyses its input binaries **before** it binds the port, which
   takes minutes on a cold project. `Wait-ServerListening` (with the `Test-TcpPortOpen` seam) now
   blocks until the port answers, up to five minutes, and warns instead of throwing on timeout.

Verified on the host afterwards: rewriting the launcher with identical arguments leaves its
timestamp alone and `Test-ServerRestartNeeded` returns `$false`, so a steady-state run no longer
touches the running server.

---

## Nothing is open

The MVP is done. Both remaining threads closed on 2026-09-06:

**Idempotency, proven.** A full elevated run at 09:01 on the current code:

```
Phase 0 (Preflight): ok in 487ms
Phase 1 (Prerequisites): already satisfied, skipping
Phase 2 (Symbols): already satisfied, skipping
Phase 3 (McpServers): ok in 2741ms      pyghidra-mcp 0.2.5 already present
                                        Scheduled task 'ReLab-pyghidra-mcp' is already current
                                        mcp-windbg 1.2.1 already present
                                        Test dump already present
Phase 4 (AgentConfig): ok in 17ms
Phase 5 (Verify): ok                    5 pass, 0 fail
Phase 6 (Manifest): ok in 6ms
```

**No restart line** — defect 7 is fixed, and a steady-state run no longer touches the running
server. The only warning is the standing 8 GB RAM advisory.

**Every enabled server answers a real tool call.** `-VerifyOnly -Attended` at 09:05, unelevated,
with x64dbg, x32dbg and Binary Ninja open: **8 pass, 0 fail, 1 not-testable** — the last being
`ghidramcp`, disabled by design. All six phases complete, manifest included.

That is all five items of the definition of done, including item 3, the one `MVP.md` calls the only
one that matters.

### Worth doing next, none of it blocking

- Drop the VERIFY note in `Test-WindbgLive`: its argument names are confirmed.
- Pin `GhidraMCP-release-1-4.zip` if anyone ever enables `ghidramcp` — and read the
  1.4-targets-Ghidra-11.3.2 vs. host-runs-12.1.2 note first.
- `MVP.md`'s "Out of scope for the MVP" list is the real backlog: skills and agents, hooks, the
  audit trail, cost caps, the verification oracle.

## Things that will bite you

- **The `Edit` and `Write` tools fail when overwriting an existing file here.** `Z:` is a VMware
  host shared folder over SMB and `fchmod` fails with `ENOENT`. Creating new files works. Route
  overwrites through a short Python script (`C:\Python313\python.exe`), which is why the history
  looks like that.
- **Never pass JSON as a native command argument from PowerShell 5.1.** It strips the double quotes
  and the failure surfaces as a JSON parse error inside whatever you called — which reads as a
  broken server, not a broken caller. Write it to a file. See defect 3 above.
- **`[CmdletBinding()]` empties `$PSScriptRoot` inside a script's param block.** Resolve
  script-relative defaults in the body. See defect 2 above.
- **Git needed `safe.directory`** for `//vmware-host/Shared Folders/REVERSING_AGENT`. Already
  configured globally.
- **Repo identity is `david <david@agent>`, repo-local.** Do not use any address from session
  context. Never add `Co-Authored-By` or AI attribution to commits.
- **This box has 8 GB RAM** against a 32 GB advisory. Ghidra + Binary Ninja + a debugger + the agent
  co-resident will swap. It is a warning, never a blocker.
- **`where.exe` returns Chocolatey shims**, not real executables — `where.exe x64dbg` gives
  `C:\ProgramData\chocolatey\bin\x64dbg.exe`, while the real tree is `C:\tools\x64dbg\release\`.
  Discovery probes known paths first and rejects anything under `\chocolatey\bin\`.
- **Zero-warnings policy is enforced.** Fix findings, or suppress inline with a justification
  comment. Do not loosen `PSScriptAnalyzerSettings.psd1`.
- **PowerShell 5.1 only.** No `??`, no `?:`, no three-argument `Join-Path`.

---

## Probing a live server by hand

Any venv that carries the `mcp` client will do. From bash, inline JSON is fine:

```bash
C:/re/mcp/venvs/pyghidra-mcp/Scripts/python.exe tools/mcp_probe.py \
  --transport=http --url=http://127.0.0.1:9094/ \
  --header="Authorization=Bearer <token from C:\tools\x64dbg\release\x64\mcp_config.json>" \
  --tool=GetDebugState
```

Arguments must be written `--opt=value`; a bare `--arg --no-symbols` is parsed by argparse as a
missing value. Omit `--tool` to get just the tool list. From PowerShell, use `--calls-file`.

---

## Shape of the code

Decision logic is pure and unit-tested; side effects are thin and mocked. Every external process
call goes through `Invoke-CommandLine` (Discovery) so tests can mock the host away entirely. Other
mock seams: `Get-MachineFact`, `Get-AppxInstallLocation`, `Test-FileContainsAscii`,
`Get-MachineSymbolPath`, `Get-ScheduledTaskActionText`, `Invoke-Download`, `Test-NetworkReachable`.

Modules depend on each other through the session, not through imports — `Install-REAgent.ps1`
imports all 11 before any run. Each module's header comment names what it expects. Tests import the
siblings they need.

`kind` in `re-agent.config.json` selects the install strategy and keeps the dispatcher generic:
`plugin-inproc`, `venv-stdio`, `venv-http`, `gui-builtin-http`, `gui-plugin-http`.
