# Live Attach Workflow

> **Disabled on this host.** This host's `mcp-windbg` 1.2.1 build advertises `open_cdb_remote`,
> `send_ctrl_break`, `wait_for_break`, and `close_cdb_session`, but live-process debugging has not
> been reviewed or explicitly enabled here. See `windbg-live-debugging` under `skills[windbg]` in
> `re-agent.config.json` for the recorded reason. This skill does not declare those tools (see its
> `allowed-tools`) and does not perform live attach; the workflow below is kept for context and
> mirrors the `windbg` pack's disabled `windbg-live-debugging` skill, which is the canonical,
> up-to-date version of it. If an operator later enables live debugging, use that skill directly
> rather than reintroducing the mechanics here.

## Purpose
Attach to a currently hung or misbehaving process through a WinDbg debug server, once enabled.

## Steps
1. Find process IDs:
```powershell
Get-Process | Where-Object { $_.ProcessName -match '<name-pattern>' } | Select-Object Id,ProcessName,StartTime
```
2. Start debug server with `cdb` (preferred):
```powershell
& "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe" -server tcp:port=5005 -p <PID>
```
3. If path differs, try:
```powershell
& "C:\Program Files\Windows Kits\10\Debuggers\x64\cdb.exe" -server tcp:port=5005 -p <PID>
```
4. Provide this connection string to MCP:
```text
tcp:Port=5005,Server=127.0.0.1
```
5. Open live session with `open_cdb_remote`.
6. Run scenario command pack via `run_cdb_command`.
7. Close with `close_cdb_session`.

## Notes
- Keep the `cdb`/`windbg` window open while MCP is connected.
- If `5005` is busy, use another port consistently in launch and connection string.
- Localhost (`127.0.0.1`) is recommended for local debugging.
- Never debug directly on a production process -- collect a dump and analyze it offline
  (`references/capture-playbooks.md`, `references/dump-workflow.md`) when this capability is
  unavailable, which it currently is on this host.
