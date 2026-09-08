---
name: windbg-doctor
description: Check that this host can actually run the mcp-windbg MCP server - CDB present, the managed server venv working, symbols configured - and explain how to fix whatever is missing. Use when mcp-windbg tools fail, when a session will not open, or before a first debugging session.
allowed-tools:
  - mcp__mcp-windbg__list_dumps
  - Bash
---

# Check the debugging setup

Diagnose why mcp-windbg is not working, or confirm it will before someone
relies on it. Report findings together at the end, not one command at a time.

## Checks

Run these with Bash and interpret the results.

**1. Platform.** `uname -s` or `$env:OS`. The server drives `cdb.exe`/`kd.exe`
and is Windows-only. On anything else, stop here and say so - nothing later will
help.

**2. CDB.** Look in the places the server itself searches:

```
C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe
%LOCALAPPDATA%\Microsoft\WindowsApps\cdbX64.exe
```

Some hosts (this one included) ship `cdb.exe` inside the WinDbg Store package
instead, under `(Get-AppxPackage -Name Microsoft.WinDbg).InstallLocation\amd64\cdb.exe`.
That path embeds the package version, so discover it rather than hardcoding it,
and check it too before concluding WinDbg is missing.

Missing means WinDbg is not installed. Point at
[aka.ms/windbg](https://aka.ms/windbg) (Microsoft Store) or the Windows SDK's
Debugging Tools for Windows. If it is installed somewhere unusual, the server
takes `--cdb-path` / `--kd-path`.

**3. The server venv.** Upstream's plugin launched the server with `uvx`. This
host does not: `Install-REAgent.ps1` builds a managed virtual environment and the
MCP entry runs its interpreter directly, so what has to exist is

```
C:\re\mcp\venvs\mcp-windbg\Scripts\python.exe
```

Missing means the venv was never built or has been removed. Re-run the
installer - do not build it, or install anything into it, from inside a session.
`uv` is what the installer uses to create that venv, so `uv --version` is worth
reporting when the venv is absent, but it is an install-time dependency only: a
missing `uv` cannot stop an already-built server from starting, and is never the
cause when the venv is there.

**4. The server itself.** Run that interpreter's module entry point:
`C:\re\mcp\venvs\mcp-windbg\Scripts\python.exe -m mcp_windbg --help`. This
proves the chain the host actually uses - the venv resolves and the pinned
`mcp-windbg` is importable. Do not substitute `uvx mcp-windbg --help`: that
resolves an unpinned latest from PyPI, needs network egress, and tests a package
this host never runs.

**4b. The registration.** `C:\re\agent\.mcp.json` must carry an `mcp-windbg`
entry whose `command` is that interpreter and whose `args` begin `-m mcp_windbg`,
with `--cdb-path` pointing at the `cdb.exe` check 2 found and `--symbols-path`
set. A working venv with no entry here, or an entry naming a stale `cdb.exe`
path, fails every tool at once and looks exactly like a missing server.

**5. Symbols.** Check `_NT_SYMBOL_PATH`. The plugin defaults it to the Microsoft
symbol server, so an empty value in the *shell* is not a problem by itself -
what matters is what the server received. Report the effective value and note
that without symbols, stacks resolve only to `module+0x1234` and any analysis
built on them is guesswork.

**6. Tools reachable.** If the MCP server is up, `list_dumps` returning anything
at all - including "no dumps found" - proves the round trip works.

## Reporting

A short table: check, result, and what to do about it. Lead with the first thing
that is actually broken, since later checks often fail only as a consequence of
it. If everything passes, say so in one line and name the CDB path and effective
symbol path you found, so the user knows what they are running against.
