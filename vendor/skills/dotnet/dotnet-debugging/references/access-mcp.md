# Access mcp-windbg

> **Quick Ref**: mcp-windbg is already registered by this install | Call tools with the
> `mcp__mcp-windbg__` prefix | Test with `open_cdb_dump` on a known dump before relying on it |
> All debugger commands, including SOS, go through `run_cdb_command`

## Tool IDs

This skill's real, dispatchable tool IDs on this host are:

- `mcp__mcp-windbg__open_cdb_dump`
- `mcp__mcp-windbg__run_cdb_command`
- `mcp__mcp-windbg__close_cdb_session`

See `references/mcp-setup.md` if any of these fail -- this install already registers and launches
`mcp-windbg`, so a failure here means the server or `cdb.exe` needs diagnosis (`windbg-doctor`),
not re-registration.
