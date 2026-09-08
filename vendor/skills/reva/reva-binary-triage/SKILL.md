---
name: reva-binary-triage
description: Performs an initial breadth-first survey of a binary in Ghidra through the pyghidra-mcp MCP server -- strings, imports/exports, symbols, and an entry-point decompile -- to quickly understand what a binary does and flag suspicious behavior before deeper reverse engineering. Use when first examining a binary, when the user asks to triage/survey/analyze a program, or wants an overview before reva-deep-analysis.
allowed-tools:
  - mcp__pyghidra-mcp__list_project_binaries
  - mcp__pyghidra-mcp__list_project_binary_metadata
  - mcp__pyghidra-mcp__import_binary
  - mcp__pyghidra-mcp__search_strings
  - mcp__pyghidra-mcp__list_imports
  - mcp__pyghidra-mcp__list_exports
  - mcp__pyghidra-mcp__search_symbols_by_name
  - mcp__pyghidra-mcp__gen_callgraph
  - mcp__pyghidra-mcp__list_xrefs
  - mcp__pyghidra-mcp__decompile_function
  - TodoWrite
---

# Binary Triage

## Instructions
We are triaging a binary to quickly understand what it does. This is an initial survey, not
deep analysis -- for that, hand off to `reva-deep-analysis`. Our goal is to:
1. Identify key components and behaviors
2. Flag suspicious or interesting areas
3. Create a task list of next steps for deeper investigation

## Binary triage with pyghidra-mcp

**This install's `pyghidra-mcp` server exposes 20 tools; the ones this skill uses are listed
above in `allowed-tools`.**
Upstream ReVa (`cyberkaida/reverse-engineering-assistant`) is a different Ghidra extension with
its own, richer tool surface -- this skill has been retargeted onto `pyghidra-mcp`'s 20 tools,
and two of upstream's eight survey steps have no equivalent here at all. Read `## Limitations`
before reporting a step as "done" -- a step marked unsupported below did not silently run; it did
not run.

Follow this workflow:

### 1. Identify the Program
- Use `list_project_binaries` to see the binaries already imported into the project
- Use `import_binary` if the target has not been imported yet
- Use `list_project_binary_metadata` for the binary you are triaging (format, architecture,
  entry point) -- `pyghidra-mcp` has no single "active program" concept the way ReVa's
  `get-current-program` did; every call below names the binary explicitly
- Note the binary's path/name for use in every subsequent tool call

### 2. Survey Memory Layout -- NOT SUPPORTED ON THIS HOST
Upstream's `get-memory-blocks` step (`.text`/`.data`/`.rodata`/`.bss` sections, packed or
writable-executable sections) has no equivalent among `pyghidra-mcp`'s 20 tools -- there is no
section/memory-block listing tool at all. Do not attempt to fake this step by guessing section
layout from decompilation. If a packed or unusual section is suspected, say so as an open
question for the analyst rather than reporting a layout you did not measure.

### 3. Survey Strings
- Use `search_strings` to search the binary's strings. Upstream's `get-strings-count` had a
  dedicated count call; `pyghidra-mcp` has none -- count the returned matches instead, and if you
  need a rough total, run a broad/empty-pattern search and count the result (confirm this
  actually returns everything before treating the number as a total, and say so if it does not).
- Paginate as the tool allows; do not request the whole string table in one call on a large binary.
- Look for indicators of functionality or malicious behavior:
  - **Network**: URLs, IP addresses, domain names, API endpoints
  - **File System**: File paths, registry keys, configuration files
  - **APIs**: Function names, library references
  - **Messages**: Error messages, debug strings, log messages
  - **Suspicious Keywords**: admin, password, credential, token, crypto, encrypt, decrypt,
    download, execute, inject, shellcode, payload

### 4. Survey Symbols and Imports
- Use `list_imports` and `list_exports` for the binary's import/export tables
- Use `search_symbols_by_name` to look up specific suspicious names once you have candidates from
  imports/strings/callgraph
- **Exclude every `ai_`-prefixed name from this survey** (see `## Trust and provenance` below) --
  a rename you or an earlier session already applied is not independent evidence
- `pyghidra-mcp` has no dedicated symbol-count tool (upstream's `get-symbols-count`); count the
  returned `list_imports`/`list_exports` results instead
- Flag interesting/suspicious imports by category:
  - **Network APIs**: connect, send, recv, WSAStartup, getaddrinfo, curl_*, socket
  - **File I/O**: CreateFile, WriteFile, ReadFile, fopen, fwrite, fread
  - **Process Manipulation**: CreateProcess, exec, fork, system, WinExec, ShellExecute
  - **Memory Operations**: VirtualAlloc, VirtualProtect, mmap, mprotect
  - **Crypto**: CryptEncrypt, CryptDecrypt, EVP_*, AES_*, bcrypt, RC4
  - **Anti-Analysis**: IsDebuggerPresent, CheckRemoteDebuggerPresent, ptrace
  - **Registry**: RegOpenKey, RegSetValue, RegQueryValue
- Note the ratio of imports to total symbols found (heavy import usage may indicate reliance on
  libraries)

### 5. Survey Functions -- PARTIALLY SUPPORTED
Upstream's `get-function-count` and `get-functions` assumed a direct enumerate-all-functions
tool. `pyghidra-mcp` has none. The closest available signal:
- Use `gen_callgraph` and count the function nodes it returns -- this is a **derived** function
  count, not a direct one, and it will miss functions with no call edges at all. State it as
  derived, never as a bare "N functions" fact.
- There is no `filterDefaultNames` equivalent to separate named from auto-named (`FUN_...`)
  functions in one call; where the callgraph or a decompile shows `FUN_`-prefixed names, treat
  that as your stripped-binary signal instead of a named/unnamed ratio.
- Identify key functions from what the callgraph and imports surfaced:
  - **Entry points**: check `list_project_binary_metadata` for the recorded entry address, then
    `decompile_function` at it
  - **Suspicious names**: if not stripped, look for revealing function names in the callgraph

### 6. Cross-Reference Analysis for Key Findings
- For interesting strings found in Step 3 and suspicious imports found in Step 4: use `list_xrefs`
  to identify which functions reference them
- This helps prioritize which functions need detailed examination

### 7. Selective Initial Decompilation
- Use `decompile_function` on the entry point and on 1-2 suspicious functions identified in Step 6
- Look for high-level patterns:
  - Loops (encryption/decryption routines)
  - Network operations
  - File operations
  - Process creation
  - Suspicious control flow (obfuscation indicators)
- **Do not do deep analysis yet** -- this is just to understand general behavior. Hand off
  specific questions to `reva-deep-analysis`.

### 8. Document Findings and Create Task List
- Use the `TodoWrite` tool to create an actionable task list with items like:
  - "Investigate string 'http://malicious-c2.com' (referenced at 0x00401234)"
  - "Decompile function sub_401000 (calls VirtualAlloc + memcpy + CreateThread)"
  - "Analyze crypto usage in function encrypt_payload (uses CryptEncrypt)"
  - "Trace anti-debugging checks (IsDebuggerPresent at 0x00402000)"
- Each todo should be:
  - Specific (include addresses, function names, strings)
  - Actionable (what needs to be investigated)
  - Prioritized (most suspicious first)
- Upstream's own Step 8 used `TodoWrite` here too -- no capability was lost in adaptation.
  `pyghidra-mcp` has no bookmark tool at all -- see `## Limitations`. `TodoWrite` is the
  session's task list; it does not persist in the Ghidra database, so a fresh session will not
  see it. Hand findings that must survive the session to `reva-deep-analysis`, which records
  them as database comments instead (see that skill's Tracking Phase).

## Output Format

Present triage findings to the user in this structured format:

### Program Overview
- **Name**: [binary name/path from list_project_binary_metadata]
- **Type**: [Executable type -- PE, ELF, Mach-O, etc., from metadata]
- **Platform**: [Windows, Linux, macOS, etc.]

### Memory Layout
**Not available on this host** -- see Step 2. Do not fill this section in from inference.

### String Analysis
- **Strings surveyed**: [count of results actually returned, not a verified total unless you
  confirmed the search was exhaustive]
- **Notable Findings**: [Bullet list of interesting strings with context]
- **Suspicious Indicators**: [URLs, IPs, suspicious keywords found]

### Import Analysis
- **External Imports**: [count from list_imports]
- **Key Libraries**: [Main libraries imported]
- **Suspicious APIs**: [Categorized list of concerning imports]

### Function Analysis
- **Functions (derived from callgraph)**: [count, marked as derived -- see Step 5]
- **Stripped indicators**: [FUN_-prefixed names observed, if any]
- **Entry Point**: [Address and name, from metadata]
- **Key Functions**: [List of important functions identified]

### Suspicious Indicators
[Bulleted list of red flags discovered, prioritized by severity]

### Recommended Next Steps
[Present the task list created in Step 8]
- Each item should be specific and actionable
- Prioritize by severity/importance
- Include addresses, function names, and context

## Trust and provenance

This host has no `SourceType` parameter on any `pyghidra-mcp` mutation tool -- the same gap the
`ghidra` pack's `ghidra-iterative-re` skill documents for this server. If triage renames anything
(it should rarely need to), use the same `ai_` name-prefix convention that skill establishes, and
exclude `ai_`-prefixed names when treating a symbol as independent evidence.

## Important Notes

- **Speed over depth**: This is triage, not full analysis. Move quickly through steps.
- **Paginate**: Don't request thousands of strings/symbols at once.
- **Focus on anomalies**: Flag things that are unusual, suspicious, or interesting.
- **Say what you could not check**: Steps 2 and 5 are degraded or unsupported on this host --
  report that plainly rather than presenting a guess as a measurement.
- **Create actionable todos**: Each next step should be specific enough for another agent to
  execute, and specific enough that `reva-deep-analysis` can start directly from it.

## Limitations

Adapted from `cyberkaida/reverse-engineering-assistant`'s `binary-triage` skill (upstream targets
its own ReVa Ghidra extension, not `pyghidra-mcp`). Capabilities that do not port to this host's
20-tool surface:

- **No memory-block/section listing** (`get-memory-blocks`). Step 2 is not performed.
- **No function enumeration or count tool** (`get-function-count`, `get-functions`). Step 5 uses
  `gen_callgraph`'s node list as a derived, non-exhaustive substitute.
- **No dedicated string- or symbol-count tool** (`get-strings-count`, `get-symbols-count`). Counts
  in this skill's output are counts of returned results, not verified totals, unless stated
  otherwise.
- **No bookmark tool** (`set-bookmark`, `search-bookmarks`) -- upstream's triage did not use
  bookmarks either, so nothing was lost here. Step 8 uses `TodoWrite` for within-session
  tracking, as upstream's triage also did; nothing persists findings into the Ghidra database
  itself. Cross-session persistence is attempted in `reva-deep-analysis`'s Tracking Phase via
  tagged `set_comment`.
