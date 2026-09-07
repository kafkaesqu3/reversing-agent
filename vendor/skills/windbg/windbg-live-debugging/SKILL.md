---
name: windbg-live-debugging
description: Attach to a running Windows process through a WinDbg debug server (via mcp-windbg) and inspect it live. Use when the user wants to debug a process on another machine, or one already under a .server session, rather than a crash dump.
allowed-tools:
  - mcp__mcp-windbg__open_cdb_remote
  - mcp__mcp-windbg__run_cdb_command
  - mcp__mcp-windbg__close_cdb_session
  - mcp__mcp-windbg__send_ctrl_break
  - mcp__mcp-windbg__wait_for_break
---

# Debug a live user-mode process

> **Disabled on this host.** This host's mcp-windbg 1.2.1 build does advertise
> `open_cdb_remote`, `send_ctrl_break`, `wait_for_break` and `close_cdb_session`,
> but live/kernel debugging has not been reviewed or explicitly enabled here.
> See `skills[windbg].skills` in `re-agent.config.json` for the recorded reason.
> Kept vendored, unmodified below, pending an operator decision to enable it.

Attach to an existing WinDbg/CDB **debug server** with the `mcp-windbg` tools.
This is user-mode only - for a kernel target use `/mcp-windbg:kernel-debug`.

## The other end

Someone must already be hosting the target. In WinDbg or CDB on that machine:

```
.server tcp:port=5005
```

If they have not, say so rather than guessing a connection string - there is
nothing to attach to yet.

## Connecting

`open_cdb_remote` with the connection string:

- TCP: `tcp:Port=5005,Server=hostname`
- Named pipe: `npipe:Pipe=pipename,Server=hostname`

The target is running when you attach, so the session may not be at a prompt.
`send_ctrl_break` halts it when you need it stopped.

## Working the target

`run_cdb_command` with the `session_id`:

- `~*k` for every thread's stack - the usual first move on a hang
- `!locks`, `!cs -l` for lock contention
- `lm`, `!peb` for what is loaded and how it started
- `bp`, `g`, `wait_for_break` to catch a code path in the act
- `.dump /ma <path>` to capture a dump for offline analysis

## Letting it run again

Attaching to a live process freezes it while broken in, and a frozen process is
usually worse than an unanalyzed one:

- `g` resumes and returns immediately; the target produces no output until it
  stops again.
- `wait_for_break` blocks until it stops on its own.
- Any ordinary command breaks in automatically first.

`close_cdb_session` when finished. Say plainly whether the target was left
running or halted, so nobody discovers a frozen process an hour later.

## Reporting

For a hang, the answer is usually the relationship between threads, not a single
stack: which thread holds what, and which are waiting on it. Say that explicitly
rather than pasting `~*k` and leaving the reader to work it out.
