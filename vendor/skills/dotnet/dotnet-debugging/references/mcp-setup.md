# MCP Setup

> **Quick Ref**: mcp-windbg is already installed and launched by this install's installer, not
> by this skill | Do not install cdb.exe, uv, or the server yourself | Use the windbg pack's
> windbg-doctor skill to diagnose a broken setup | Verify with a basic run_cdb_command call first

## This install manages mcp-windbg's lifecycle -- this skill does not

`mcp-windbg` 1.2.1 is one of this repository's pinned MCP servers (`re-agent.config.json`,
`mcpServers[].name == "mcp-windbg"`), installed into a managed Python venv and launched as a
stdio server by `Install-REAgent.ps1`. Registering it, installing `cdb.exe`, or installing `uv`/
`uvx` are installer responsibilities, already done before this skill ever runs -- **do not attempt
any of that from inside a debugging session.** Installing or reconfiguring tools mid-session is
outside this install's reviewed tool surface, the same reason `re-unpacker`'s upstream package-
manager bootstrap was removed rather than adapted.

## If mcp-windbg tools are failing

Run the `windbg` pack's `windbg-doctor` skill first. It checks platform, `cdb.exe` presence (in
all the places this host's server actually looks, including the WinDbg Store package path), the
managed venv interpreter and its `python -m mcp_windbg` entry point, this host's `.mcp.json`
registration, and the effective symbol path -- the full diagnostic this file used to duplicate
with install instructions instead of checks.

## Validate availability

Before debugging, confirm `mcp-windbg` tools are callable by opening a known dump with
`open_cdb_dump` and issuing one `run_cdb_command` (for example `lm`).
