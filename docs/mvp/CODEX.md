# Codex installer

The main installer configures Claude Code and Codex together. Run it from the repository
directory in Windows PowerShell 5.1 or later:

```powershell
.\Install-REAgent.ps1
```

A full run requires an elevated shell **under the analyst's Windows account** on
the FLARE VM. Both Claude Code and Codex CLI must already be installed.
Authentication remains interactive. The standalone `install-codex.ps1` does not
require Claude Code.

To reconcile Codex by itself after the services are installed, use:

```powershell
.\install-codex.ps1 -ConfigureOnly
```

This reads the recorded installation and merges its MCP entries into Codex without
installing packages, replacing plugins, changing symbols, or restarting services.
It can run unelevated when the analyst can read the existing tokens and write the
report directory. Both modes run unattended live checks after registration.

## Configuration and verification

The default destination is `$env:CODEX_HOME\config.toml`, or
`$env:USERPROFILE\.codex\config.toml` when `CODEX_HOME` is unset. Override the
directory with `-CodexHome`. Override the source JSON with `-ConfigPath`.

```powershell
.\install-codex.ps1 -WhatIf
.\install-codex.ps1 -VerifyOnly
.\install-codex.ps1 -VerifyOnly -Attended
```

`-WhatIf` validates the source JSON and reports the operation without changing the
host. `-VerifyOnly` writes a verification report but does not change Codex settings
or reinstall services. `-Attended` includes the debugger and Binary Ninja checks.

| Server | Codex transport | Availability |
|---|---|---|
| `x64dbg-x64` | HTTP, `http://127.0.0.1:9094/` | Open x64dbg with a target loaded |
| `x64dbg-x32` | HTTP, `http://127.0.0.1:9095/` | Open x32dbg with a target loaded |
| `binaryninja` | HTTP, `http://127.0.0.1:24642/mcp` | Open a binary; run **Plugins > MCP > Start Server** each session |
| `pyghidra-mcp` | HTTP, `http://127.0.0.1:8762/mcp` | Existing logon Scheduled Task |
| `mcp-windbg` | stdio, discovered venv and explicit `cdb.exe` path | Codex starts it on demand |
| `pdbsql` | Legacy SSE, omitted | Installed for Claude; Codex requires a supported transport or bridge |
| `ghidrasql` | Legacy SSE, omitted | Installed for Claude; Codex requires a supported transport or bridge |
| `ghidramcp` | Legacy SSE, omitted | Disabled in the MVP; version 1.4 targets Ghidra 11.3.2 and is incompatible with the measured 12.1.2 host |

Legacy SSE servers are skipped with an explanation while compatible servers are still
reconciled. They require Streamable HTTP support or a stdio bridge; treating an SSE URL as
Streamable HTTP would produce a broken entry. Keep the working `pyghidra-mcp` default.

The installer uses the existing token files for Binary Ninja and both x64dbg
entries. Tokens are stored in Codex's `http_headers` settings and are never printed
by the configuration writer. pyghidra remains loopback-only without authentication,
as established in `MVP_FINDINGS.md`. Config backups also contain these local tokens.

Restart Codex after installation, then use `/mcp` to inspect active connections.
`codex mcp list` reports configuration; it does not prove a live tool call worked.
The installer separately checks actual decompilation, WinDbg symbols, and, when
requested, debugger state and Binary Ninja views with the existing MCP probes.
These probes are SDK clients; they are not an inference session inside Codex.

## Preservation and reports

Only the RE Lab server names declared in the source JSON are reconciled. Existing
entries with those names are replaced; unrelated MCP servers and Codex settings
are preserved. A managed block holds the generated tables. Codex parses a temporary
copy before replacement, and malformed configuration leaves the original intact.
Changed files receive a `config.toml.<unique-id>.bak` backup. An unchanged run leaves
the configuration and backups untouched.

The standalone script reuses the main installer's service setup but does not install the
Claude-specific skills. `Install-REAgent.ps1` remains the normal combined entry point.

Reports live under `paths.stateRoot` from the JSON configuration:

- `codex-manifest.json`: installation metadata, source pins/hashes, server state,
  verification results, authentication exceptions, and manual steps.
- `codex-verify-report.json`: registration and live tool check results.

`-ConfigureOnly` and `-VerifyOnly` prefer the Codex installation manifest and fall
back to the original `manifest.json` when no Codex manifest exists. Verification
does not overwrite installation state. Exit codes are `0` for a completed run with
no failures, `1` for installation/configuration/verification failures, and `2` for
preflight blockers. GUI checks omitted without `-Attended` are `not-testable`.

## Review of the original MVP documents

`MVP_PLAN.md` and much of `MVP_SPEC.md` describe the historical Claude build.
`MVP_FINDINGS.md` and the closing evidence in `HANDOFF.md` supply the measured
corrections: separate debugger ports, `/` endpoints, HTTP for pyghidra symbol
loading, explicit MSIX `cdb.exe`, and per-session Binary Ninja startup. This Codex
extension uses those corrected contracts and the existing implementation.

Codex supports stdio and streamable HTTP tables in `config.toml`, including static
HTTP headers and disabled entries. See the [official Codex MCP documentation](https://developers.openai.com/codex/mcp).

## Validation on 2026-09-06

- 84 tests passed across Codex configuration, shared discovery, and manifest replay.
- PSScriptAnalyzer reported zero warnings/errors in the changed PowerShell files.
- A temporary Codex home adopted the VM's existing installation: all five enabled
  entries parsed, pyghidra returned C for `winver.exe`, and WinDbg listed `ntdll`
  with symbols resolved. A repeat run left the generated TOML unchanged.
- `-WhatIf` created no destination; `-VerifyOnly` preserved installation state.
  Deliberately changing a configured URL caused verification to exit with code 1.
- GUI applications were not open, so attended checks were not exercised. A full
  privileged installation was not rerun; the existing server installers are reused.
- The broader suite had one unrelated failure in the unchanged Ghidra skill test:
  its `^## Limitations$` expression rejects the file's CRLF line ending. The
  heading exists and matches `^## Limitations\r?$`.

All Codex configuration writes during validation used temporary directories; the
analyst's active Codex configuration was not changed.

## Project workspace and attended acceptance

Trust `C:\re\agent` when Codex asks. Trust is required for Codex to load the project
`AGENTS.md`, `.agents/skills`, and `.codex/agents` layers. After reconciliation, start a new
session with the exact command below:

```powershell
codex --strict-config -C C:\re\agent
```

Use `/skills` to verify exactly these eleven names:
`windbg-crash-analysis`, `windbg-doctor`, `ghidra-iterative-re`, `re-ioc-extraction`,
`re-unpacker`, `route-triage`, `reva-binary-triage`, `reva-deep-analysis`,
`dotnet-debugging`, `tob-trailmark`, and `arch-architectural-analysis`. The agent picker must
offer `static-analyst` and `verifier`; `dynamic-analyst` remains disabled and must not appear.

Custom-agent MCP tables deliberately repeat complete transports. This follows the measured Codex
runtime requirement: a table containing only `enabled` and `enabled_tools` is rejected as an
invalid transport. Generated project agent files can therefore contain local HTTP endpoints or
stdio commands, arguments, and safe environment entries, but never bearer values, authorization
headers, tokens, or credentials. Legacy SSE servers remain Claude-only until a supported
Streamable HTTP or stdio bridge exists.

Record these direct observations as L0-L5 in `codex-verify-report.json`; they are attended
evidence, separate from the deterministic C0-C8 results.

| ID | Observation | Required evidence |
|---|---|---|
| L0 | Instruction source | Codex names `AGENTS.md` among loaded instructions. |
| L1 | Eleven skills | `/skills` output lists exactly the eleven names above. |
| L2 | Two custom agents | Picker shows `static-analyst` and `verifier`, and excludes `dynamic-analyst`. |
| L3 | Verifier tool boundary | Verifier cannot see pyghidra write or destructive tools. |
| L4 | Specialist read-only MCP call | A specialist successfully calls a catalog read tool, such as `list_project_binaries`, `decompile_function`, or `list_dumps`. |
| L5 | Optional GUI host startup | Codex starts successfully while x32dbg remains closed. |
