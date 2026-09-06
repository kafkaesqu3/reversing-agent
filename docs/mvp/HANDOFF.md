# Handoff — Install-REAgent

**State as of 2026-09-04.** Read this first, then `MVP_FINDINGS.md`, then `MVP_SPEC.md`.

Branch `feat/install-re-agent`, 16 commits, working tree clean.
**254 Pester tests passing, zero PSScriptAnalyzer findings.**

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
Invoke-Pester -Path tests/ -Output Normal          # expect 254 passed, 0 failed
Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse   # expect no output
```

If Pester or PSScriptAnalyzer are missing, install them — but the obvious command fails on this box.
See `MVP_PLAN.md` Task 1 Step 1 for the NuGet bootstrap that makes it work.

---

## What is done

All 16 tasks are implemented: 11 modules under `src/`, the `Install-REAgent.ps1` entry point,
`tools/mcp_probe.py`, `templates/CLAUDE.md.template`, and `re-agent.config.json` with real pins.

The installer runs end-to-end today. Unelevated it correctly aborts at Phase 0 with **exit code 2**
and the message `Not running as Administrator`, having emitted the 8 GB RAM warning. That is the
expected behaviour, not a bug.

The whole tool chain is proven independently of the installer: `uv` venv → pyghidra 3.1.0 →
Ghidra 12.1.2 on JDK 25 → MCP `initialize` (20 tools) → `decompile_function` returning real C for
`winver.exe`'s entry point. **The build risk is packaging and idempotency, not tool compatibility.**

---

## What is NOT done — pick up here

### 1. The elevated end-to-end run (the actual next step)

Nothing beyond this point can be validated without it. From an **elevated** PowerShell,
**as the analyst user** (Claude Code installs per-user to `%USERPROFILE%\.local\bin`):

```powershell
cd Z:\REVERSING_AGENT
.\Install-REAgent.ps1
```

**Expect it to stop on x64dbg**, deliberately. `Get-VerifiedRelease` refuses the `PIN-ME`
placeholder hash and prints the real SHA-256 of `x64dbg-MCP-Server-v1.3.zip`. Paste that into
`re-agent.config.json` under `mcpServers[x64dbg-x64].source.sha256` **and** `[x64dbg-x32]` (same
asset, same hash), then re-run. This is trust-on-first-use made explicit, not a defect.

Then: run `claude` once interactively in `C:\re\agent` and accept the trust prompt, or
`claude mcp list` will show nothing connected no matter what the settings say.

### 2. Confirm where x64dbg writes `mcp_config.json`

The one genuinely open question. Upstream contradicts itself: the README says beside
`x64dbg.exe`, the source says beside the loading module (the plugins dir). `Write-X64dbgPreseed`
writes the first; `Install-PluginInprocServer` reads a token back from either. After the first real
x64dbg launch, check which file the plugin actually touched and, if it is the plugins dir, change
`Get-X64dbgConfigPath`'s ordering. **Pre-seeding the wrong path fails silently.**

### 3. Live tool calls for x64dbg and Binary Ninja (tier 2)

Deliberately unimplemented. I do not know their real tool names and guessing would produce confident
false failures. `Test-HttpServerLive` already handles everything else; it reports `not-testable` and
**prints the server's actual advertised tool list**. To finish:

1. Run `.\Install-REAgent.ps1 -VerifyOnly -Attended` with the app open.
2. Read the tool names out of the `not-testable` detail.
3. Add to the server's config entry:
   ```json
   "verify": { "tool": "<real name>", "args": { }, "expect": "<regex>" }
   ```
4. Re-run. The check goes live with no code change.

### 4. Verify mcp-windbg's tool argument names

`Test-WindbgLive` assumes `open_cdb_dump{dump_path}` and `run_cdb_command{command}`. Tool *names*
are confirmed from upstream docs; the *parameter* names are not. Marked VERIFY in the code.

---

## Things that will bite you

- **The `Edit` and `Write` tools fail when overwriting an existing file here.** `Z:` is a VMware
  host shared folder over SMB and `fchmod` fails with `ENOENT`. Creating new files works. Route
  overwrites through a short Python script (`C:\Python313\python.exe`), which is why the history
  looks like that.
- **Git needed `safe.directory`** for `//vmware-host/Shared Folders/REVERSING_AGENT`. Already
  configured globally.
- **Repo identity is `david <david@agent>`, repo-local.** Do not use any address from session
  context. Never add `Co-Authored-By` or AI attribution to commits.
- **This box has 8 GB RAM** against a 32 GB advisory. Ghidra + Binary Ninja + a debugger + the agent
  co-resident will swap. It is a warning, never a blocker.
- **`where.exe` returns Chocolatey shims**, not real executables. Discovery probes known paths first
  and rejects anything under `\chocolatey\bin\`.
- **Zero-warnings policy is enforced.** Fix findings, or suppress inline with a justification
  comment. Do not loosen `PSScriptAnalyzerSettings.psd1`.
- **PowerShell 5.1 only.** No `??`, no `?:`, no three-argument `Join-Path`.

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
