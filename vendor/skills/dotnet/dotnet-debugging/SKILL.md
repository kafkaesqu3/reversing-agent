---
name: dotnet-debugging
description: Debug Windows crash dumps, hangs, high CPU, and managed-memory pressure for native, .NET/CLR, or mixed-mode processes using the mcp-windbg MCP server (SOS commands like !analyze, !clrstack, !dumpheap, !gcroot, !syncblk, !dlk, !runaway issued through run_cdb_command). Spans 16 topic areas covering dump-based triage on this Windows-only install. Do not use for routine .NET SDK profiling, benchmark design, or CI test debugging -- this install vendors only the debugging skill from its upstream plugin, not the sibling profiling/testing/tooling skills.
license: MIT
user-invocable: false
allowed-tools:
  - mcp__mcp-windbg__open_cdb_dump
  - mcp__mcp-windbg__run_cdb_command
  - mcp__mcp-windbg__close_cdb_session
---

# dotnet-debugging

## Overview

Windows debugging of crash dumps, hangs, high CPU, and memory pressure using the `mcp-windbg`
MCP server. Applicable to any process on this host -- native, managed (.NET/CLR), or mixed-mode.
SOS (Son of Strike, the .NET debugging extension) commands are plain CDB commands here: every
`!clrstack`, `!dumpheap`, `!gcroot`, etc. below is an argument to `run_cdb_command`, not a call to
a dedicated .NET tool -- `mcp-windbg` has no such tool, and none is needed. Guides investigation of
crash dumps, application hangs, high CPU, and memory pressure through structured command packs and
a report template.

**Platform:** Windows only, via `cdb.exe` behind `mcp-windbg`. This install does not vendor or run
`dotnet-dump`, `lldb`, `createdump`, or `dotnet-monitor` -- see `## Limitations`.

## Routing Table

> **Path resolution**: The Companion File column lists filenames relative to this skill's
> directory. Use Glob to locate the file, then pass the returned absolute path to the Read tool.
> Do NOT use bare relative paths -- the Read tool resolves them relative to the user's project
> directory, not this skill's location.

| Topic | Keywords | Description | Companion File |
|-------|----------|-------------|----------------|
| MCP setup | mcp-windbg, cdb, doctor | Confirming this install's mcp-windbg is ready | references/mcp-setup.md |
| MCP access | tool IDs, dispatch | Which mcp-windbg tools this skill uses | references/access-mcp.md |
| Common patterns | debug patterns, SOS, CLR | Common debugging patterns | references/common-patterns.md |
| Dump workflow | dump file, .dmp, crash dump | Dump file analysis workflow | references/dump-workflow.md |
| Live attach | live process, cdb, attach | Live process attach -- disabled on this host | references/live-attach.md |
| Symbols | symbol server, .symfix, PDB | Symbol configuration | references/symbols.md |
| Sanity check | verify, environment, baseline | Sanity check procedures | references/sanity-check.md |
| Scenario packs | command pack, triage, workflow | Scenario command packs | references/scenario-command-packs.md |
| Capture playbooks | capture, procdump, triggers | Capture playbooks | references/capture-playbooks.md |
| Report template | diagnostic report, evidence | Diagnostic report template | references/report-template.md |
| Crash triage | crash, exception, access violation | Crash triage | references/task-crash.md |
| Hang triage | hang, deadlock, freeze | Hang triage | references/task-hang.md |
| High-CPU triage | high CPU, runaway thread, spin | High-CPU triage | references/task-high-cpu.md |
| Memory triage | memory leak, heap, LOH | Memory leak triage | references/task-memory.md |
| Kernel dump triage | kernel, BSOD, bugcheck | Kernel-dump (static) triage | references/task-kernel.md |
| Unknown triage | unknown issue, general triage | Unknown issue triage | references/task-unknown.md |

## Scope

- Crash dump analysis (`.dmp` files) on Windows
- Hang and deadlock diagnosis (thread analysis, lock detection, wait chains)
- High CPU triage (runaway thread identification)
- Memory pressure and leak investigation (managed heap, native heap)
- Kernel-dump triage (BSOD / bugcheck analysis of a static dump file)
- SOS commands via `run_cdb_command`
- Structured diagnostic reports with stack evidence

## Out of scope on this install

Upstream's `dotnet-artisan` plugin ships this skill alongside eleven siblings
(`dotnet-tooling`, `dotnet-testing`, `dotnet-devops`, etc.) that this install does not vendor --
there is no server or reviewed tool surface for them here. If a task calls for one of these, say
so plainly rather than attempting it with `mcp-windbg`:

- Performance profiling, `dotnet-counters`, `dotnet-trace`
- GC tuning and managed memory optimization outside a live incident
- Assembly decompilation (ILSpy)
- Performance benchmarking and regression detection
- Application-level logging and observability
- Unit/integration test debugging
- Linux/macOS debugging (`dotnet-dump`, `lldb` with SOS, `createdump`), container and Kubernetes
  diagnostics, and `dotnet-monitor` -- this install is Windows-only and none of these tools are
  part of its pinned surface

## MCP Tool Contract

These are `mcp-windbg` 1.2.1's real exported tool names, verified against this host's
`data/tool-catalog.json` and dispatched with the `mcp__mcp-windbg__` prefix. This skill uses three
of the ten:

| Operation | Purpose |
|-----------|---------|
| `mcp__mcp-windbg__open_cdb_dump` | Open a saved dump file |
| `mcp__mcp-windbg__run_cdb_command` | Execute a debugger command, including every SOS command below (`!clrstack`, `!dumpheap`, `!gcroot`, ...) |
| `mcp__mcp-windbg__close_cdb_session` | Close the dump session |

`mcp-windbg` also exports `open_cdb_remote`, `run_kd_command`, `open_kd_session`, and their
counterparts for live and kernel sessions -- this skill does not declare or use them. See
`## Limitations`.

## Diagnostic Workflow

### Preflight: Symbols

Before any analysis, configure symbols to get meaningful stacks. Issue each line below through
`run_cdb_command`:

1. Set Microsoft symbol server: `.symfix` (sets `srv*` to Microsoft public symbols)
2. Add application symbols: `.sympath+ C:\path\to\your\pdbs`
3. Reload modules: `.reload /f`
4. Verify: `lm` (list modules -- check for "deferred" vs "loaded" status)

Without correct symbols, stacks show raw addresses instead of function names.

### Crash Dump Analysis

1. Open dump: `open_cdb_dump` with the dump file path
2. Load SOS for managed code (`run_cdb_command`): `.loadby sos clr` (Framework) or
   `.loadby sos coreclr` (.NET Core)
3. Get exception context (`run_cdb_command`): `!pe` (print exception), `!analyze -v` (automatic
   analysis)
4. Inspect threads (`run_cdb_command`): `~*e !clrstack` (all managed stacks), `!threads`
   (thread list)
5. Check managed heap (`run_cdb_command`): `!dumpheap -stat` (heap summary), `!gcroot <addr>`
   (object roots)
6. Close with `close_cdb_session`

### Hang / Deadlock Diagnosis

1. Open dump, load SOS (as above)
2. List all threads (`run_cdb_command`): `!threads`, identify waiting threads with `!syncblk`
   (sync block table)
3. Detect deadlocks: `!dlk` (SOS deadlock detection)
4. Inspect thread stacks: `~Ns !clrstack` for specific thread N
5. Check wait reasons: `!waitchain` for COM/RPC chains, `!mda` for MDA diagnostics

### High CPU Triage

1. Collect multiple dumps 10-30 seconds apart (see `references/capture-playbooks.md`), open each
2. Use `!runaway` to identify threads consuming the most CPU time
3. Inspect hot thread stacks: `~Ns kb` (native stack), `~Ns !clrstack` (managed stack)
4. Look for tight loops, blocked finalizer threads, or excessive GC

### Memory Pressure Investigation

1. Open dump, load SOS
2. Managed heap: `!dumpheap -stat` (type statistics), `!dumpheap -type <TypeName>` (filter)
3. Find leaked objects: `!gcroot <address>` (trace GC roots to pinned or static references)
4. Native heap: `!heap -s` (heap summary), `!heap -l` (leak detection)
5. LOH fragmentation: `!eeheap -gc` (GC heap segments)

## Report Template

```
## Diagnostic Report

**Symptom:** [crash/hang/high-cpu/memory-leak]
**Process:** [name, PID, bitness]
**Dump type:** [full/mini]

### Evidence
- Exception: [type and message, or N/A]
- Faulting thread: [ID, managed/native, stack summary]
- Key stacks: [condensed callstack with module!function]

### Root Cause
[Concise analysis backed by stack/heap evidence]

### Recommendations
[Numbered action items]
```

## Guardrails

- Do not claim certainty without callee-side evidence
- Do not call it a deadlock unless lock/wait evidence supports it
- Preserve user privacy: do not include secrets from environment blocks in reports

## Limitations

This install vendors only `dotnet-debugging` out of upstream `fenzel999/dotnet-artisan`'s twelve
skills -- the eleven siblings referenced by upstream's cross-links (`dotnet-tooling`,
`dotnet-testing`, `dotnet-devops`, etc.) are not present under `.claude/skills/` here. Treat any
`[skill:dotnet-*]` reference as removed content, not a live pointer.

`mcp-windbg`'s live-attach and kernel-session tools (`open_cdb_remote`, `open_kd_session`,
`run_kd_command`, and related) exist on this host's build but are administratively disabled
pending an operator decision -- see `windbg-live-debugging` and `windbg-kernel-debug` in the
`windbg` pack (`re-agent.config.json`). `references/live-attach.md` describes the workflow for
context but this skill does not declare those tools and does not perform live attach. Kernel-dump
(static `.dmp` from a BSOD) triage is unaffected -- it is ordinary dump analysis through
`open_cdb_dump`.

Upstream's TTD (Time Travel Debugging) and full-WinDbg-app gotchas that apply to this host's
in-box `dbgeng.dll` are documented once, in the `windbg` pack's `windbg-crash-analysis` skill --
not repeated here to avoid two copies drifting apart.

## References

- [mcp-windbg](https://github.com/svnscha/mcp-windbg) -- the MCP server this skill actually
  drives on this host (upstream cited `github.com/anthropics/windbg-mcp`, which does not exist;
  removed rather than carried forward)
- [WinDbg Documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/) --
  Microsoft debugger documentation
