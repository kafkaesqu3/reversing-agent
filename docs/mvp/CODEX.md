# Codex installer

Run from the repository directory in Windows PowerShell 5.1 or later:

```powershell
.\install-codex.ps1
```

A full run requires an elevated shell **under the analyst's Windows account** on
the FLARE VM. Codex CLI must already be installed and available as `codex`.
Authentication to Codex remains interactive. Claude Code is not required.

If the original MVP installer has already set up the services, use:

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
| `ghidramcp` | Legacy SSE, omitted | Disabled in the MVP; version 1.4 targets Ghidra 11.3.2 and is incompatible with the measured 12.1.2 host |

Enabling legacy `ghidramcp` is rejected with an explanation. It would require a
compatible extension and a stdio bridge; treating its SSE URL as streamable HTTP
would produce a broken entry. Keep the working `pyghidra-mcp` default.

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

The existing Claude installer and its generated files remain available. This script
reuses its service setup but does not install the Claude-specific skills.

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
