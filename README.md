# REVERSING_AGENT

Wires Claude Code and Codex to a reverse-engineering toolchain on an existing
FLARE VM via MCP: x64dbg, Ghidra, Binary Ninja, WinDbg, and a SQL query layer over Ghidra/PDB
symbols. One script inventories the host, installs only what's missing, and generates all agent
configuration from `re-agent.config.json` — idempotent, so a second run changes nothing.

**Read `docs/mvp/HANDOFF.md` first**, then `docs/mvp/MVP_SPEC.md`. `docs/mvp/MVP.md` tracks
status; `docs/GAP_ANALYSIS.md` and `docs/BLUEPRINT.md` describe the broader system this MVP is
the first slice of.

## What it delivers

A single elevated PowerShell run on a FLARE VM (an *existing* one — this adopts and reconciles,
it does not assume a clean baseline) leaves you with:

1. `claude --version` and `claude doctor` succeeding.
2. `claude mcp list` showing every enabled server connected.
3. Codex reading every installed MCP server whose transport it supports.
4. Each server answering a real tool call against a known test binary.
5. A `manifest.json` recording every component, version, source, and hash installed.

## MCP servers

| Tool | Server | Transport | Notes |
|---|---|---|---|
| x64dbg (x64/x32) | `duty1g/x64dbg-mcp-server` | HTTP+SSE, `:9094`/`:9095` | One server per architecture — the port is compiled in from pointer width |
| WinDbg | `svnscha/mcp-windbg` | stdio | Wraps `cdb.exe` from the WinDbg MSIX package |
| Ghidra | `clearbluejar/pyghidra-mcp` | streamable-http, `:8762` | Default backend; headless |
| Ghidra (alt) | `LaurieWired/GhidraMCP` | SSE | Installed but disabled — escape hatch, not a default |
| `ghidrasql` | `0xeb/ghidrasql` | SSE, `:8771` | SQL query layer over a Ghidra project via the LibGhidraHost extension |
| `pdbsql` | native binary | `:8770` | SQL query layer over PDB symbols, resolved through the symbol-server tree |
| Binary Ninja | official built-in server | HTTP, `:24642/mcp` | Enabled via Binary Ninja's own settings; does not autostart |

## Usage

```powershell
# Full install
.\Install-REAgent.ps1

# Verify only, including tier-2 checks that need GUI tools open
.\Install-REAgent.ps1 -VerifyOnly -Attended

# Reconcile Codex by itself, without running the combined installer
.\install-codex.ps1 -ConfigureOnly
```

Codex supports the STDIO and Streamable HTTP entries. The legacy SSE-only `pdbsql`,
`ghidrasql`, and disabled `ghidramcp` entries remain available to Claude and are reported as
skipped for Codex until they gain a supported transport or bridge.

RUN ONLY ON A VIRTUAL MACHINE. Requires Administrator for a full install.

## Layout

- `src/ReAgent.*.psm1` — phase implementations, imported by `Install-REAgent.ps1`
- `tools/` — standalone build/probe scripts (e.g. `Build-LibGhidraExtension.ps1`, `mcp_probe.py`)
- `re-agent.config.json` — the single source of config that `.mcp.json` and friends are generated from
- `data/tool-catalog.json` — observed server/tool baseline, refreshed via `-UpdateToolCatalog`
- `tests/` — Pester tests for the PowerShell modules
- `vendor/skills/` — vendored, gated skill packs (see `docs/mvp/SKILLS_SIGNOFF.md`)
- `docs/mvp/` — MVP spec, findings, handoff, and status
