---
name: windbg-crash-analysis
description: Triage a Windows crash dump using the mcp-windbg MCP server - identify the exception, the faulting frame, and what to look at next. Use when the user points at a .dmp file or asks why a Windows process crashed.
allowed-tools:
  - mcp__mcp-windbg__open_cdb_dump
  - mcp__mcp-windbg__run_cdb_command
---

# Analyze a Windows crash dump

Work through a `.dmp` file with the `mcp-windbg` MCP server and report what actually
crashed, not just what the debugger printed.

## Getting a dump path

Ask the user for the `.dmp` path directly. This install has no `list_dumps` tool to
browse a crash-dump directory with - see Limitations.

## Triage

1. `open_cdb_dump` with the path. Pass `include_stack_trace: true`; add
   `include_modules` or `include_threads` only if the question calls for them.
   Keep the returned `session_id` for every follow-up call.
2. `run_cdb_command` with `!analyze -v`. This is the single most informative
   command and belongs in every triage.
3. Follow the evidence with further `run_cdb_command` calls. Useful next steps:
   - `k` / `kb` for the call stack with arguments
   - `lm` to see whether the faulting module has symbols
   - `.exr -1`, `.ecxr` for the exception record and context
   - `dt`, `dx`, `db`/`dd` to inspect the data the crash implicates
4. There is no `close_cdb_session` tool in this install - see Limitations. Say
   plainly that you are done with the dump; there is nothing left to close.

## Reporting

Lead with the answer: what failed, where, and why, in the first two sentences.
Then support it - exception code and its meaning, the faulting frame, and the
specific evidence that points there.

Two things worth being explicit about:

- **Say when symbols are missing.** A stack full of `module+0x1234` is a
  symbol problem, not an analysis result. Say so rather than reading meaning
  into offsets, and mention `_NT_SYMBOL_PATH`.
- **Separate fact from inference.** "The access violation is at a null `this`
  pointer" is a fact from the register state. "This is probably a use-after-free"
  is a hypothesis - label it as one and say what would confirm it.

If the dump does not support a conclusion, say that. An honest "this dump only
shows the crash point, not the cause, and here is what would" is more useful
than a confident guess.

## Limitations

- This install exposes only two mcp-windbg tools: `open_cdb_dump` and
  `run_cdb_command`. The upstream skill also reaches for `list_dumps` to browse
  a dump directory and `close_cdb_session` to end a session cleanly; neither is
  in this host's mcp-windbg 1.2.1 pin, which is a dump-only, two-tool surface
  (see `data/tool-catalog.json`). Ask the user for dump paths directly, and do
  not expect an explicit close step.
- Two `dbgeng.dll` gotchas, carried over from evaluating `glslang/windbg-mcp`
  (a different WinDbg MCP server, not vendored here), apply to the debugging
  engine this host runs too: replaying a Time Travel Debugging (TTD) `.run`
  trace fails against the in-box engine with `0x80070057`, so say up front that
  TTD replay is not available through this install if a user hands you a `.run`
  file. And the deeper parts of `!analyze` that ship only with the full
  packaged WinDbg app - rather than the redistributable `cdb.exe` this server
  drives - are not guaranteed to be present. `!analyze -v` is still expected to
  work for the common exception classes; treat a thin or unhelpful verdict on
  an unusual bugcheck as an engine-depth gap, not proof there is nothing to
  find, and say so rather than guessing further.
