---
name: arch-architectural-analysis
description: User-triggered deep structural analysis of a stripped binary analyzed through the pyghidra-mcp MCP server, across the modes that survive the source-to-binary retarget -- integrations (imported/exported APIs, network and file-system boundaries), control flow, data flow, and failure modes -- with information architecture, data model, UI surfaces, and interaction patterns marked NOT SUPPORTED (see the mode table). This skill should be used when the user asks to "diagram this binary," "map what it talks to," "trace control flow," "find the imported APIs," or any similar request whose primary deliverable is mermaid diagrams plus address-cited reports under docs/architecture/. Dispatches haiku/sonnet sub-agents in parallel for per-mode evidence-gathering over pyghidra-mcp tool output, then verifies every citation mechanically -- by re-querying pyghidra-mcp, not by reading source files -- before any node lands in a diagram. Not for one-off prose explanations (use reva-deep-analysis) or for a first-pass survey of an unfamiliar binary (use reva-binary-triage).
keywords:
  - architectural analysis
  - diagram this binary
  - map what it talks to
  - control flow
  - integration points
license: MIT
allowed-tools:
  - Agent
  - Bash
  - Write
  - Read
  - mcp__pyghidra-mcp__list_project_binary_metadata
  - mcp__pyghidra-mcp__decompile_function
  - mcp__pyghidra-mcp__disassemble
  - mcp__pyghidra-mcp__list_xrefs
  - mcp__pyghidra-mcp__gen_callgraph
  - mcp__pyghidra-mcp__list_imports
  - mcp__pyghidra-mcp__list_exports
  - mcp__pyghidra-mcp__search_strings
  - mcp__pyghidra-mcp__search_symbols_by_name
---

# Architectural Analysis (binary-graph adaptation)

## Overview

Upstream produces diagram-first architectural reports for a **source-code** repo or subtree,
grounding every node and edge in a `path:line` citation. This host analyzes **stripped binaries**
through `pyghidra-mcp` -- there is no source tree, no git history, no README/CLAUDE.md doc spine,
and no `grep`/`Read`-over-files verification path. The primary artifact is unchanged in shape --
mermaid diagrams under `docs/architecture/<report-date>/<mode>/` plus markdown reports -- but
every citation is now **function name + address**, verified by re-querying `pyghidra-mcp`, not by
reading a file at a line number.

Upstream's contract stands: *"Every node and every edge in every diagram is grounded in the
source -- no exceptions outside the explicit synthesized-concept escape hatch."* On this host,
read "the source" as "pyghidra-mcp's own analysis of the binary" throughout.

## Mode support on this host

Upstream's eight modes assume a source-code/web-application codebase -- imports, JSX, ARIA roles,
ORM model classes, `async`/`await` syntax, `try`/`except` blocks. A single stripped binary has
none of the source-level constructs most of that signal catalog looks for. Per mode:

| Mode | Status on this host | Why |
|---|---|---|
| Integrations (`X-`) | **Adapted** -- see `references/mode-integrations.md` | Imported/exported APIs, network syscalls, and file-system contracts are directly visible via `list_imports`/`list_exports`/`search_strings` -- this is the same ground `reva-binary-triage`'s suspicious-import categories cover, at diagram granularity. |
| Control flow (`C-`) | Conceptually applicable, reference file **not rewritten** | Branches, loops, and call structure exist in disassembly/decompilation, but the mode's entire signal catalog (`asyncio`, `Promise.all`, Textual/React lifecycle hooks) is source/framework-specific. Ground nodes in `decompile_function`/`gen_callgraph`/`list_xrefs` output instead of the listed signals; the diagram *shape* (state machine / sequence) is still the right one for a state machine or thread-lifecycle you find in decompiled code. |
| Data flow (`D-`) | Conceptually applicable, reference file **not rewritten** | The source→transform→sink shape maps to network/file I/O traced via `decompile_function` + `list_xrefs` (the same investigation shape `reva-deep-analysis` already uses for "what's the C2 address?"-style questions), but the listed signals (argparse, HTTP framework decorators, ORM) are source-specific. |
| Failure modes (`F-`) | Conceptually applicable, reference file **not rewritten** | Native error handling (checked return codes, SEH/exception frames, `GetLastError`) exists, but `try`/`except` syntax detection does not apply -- you are reading control-flow structure in decompiled output for the equivalent shape, not scanning source syntax. |
| Information architecture (`I-`) | **NOT SUPPORTED** | Assumes a package/module source layout (`__init__.py`, directory hierarchy). A single compiled binary has no such structure; `pyghidra-mcp` has no section/memory-block listing tool either (the same gap `reva-binary-triage` documents). Do not attempt this mode. |
| Data model (`M-`, ERD) | **NOT SUPPORTED** | Assumes an ORM/DB schema or typed source declarations. Inferred struct layouts from `set_variable_type`/decompilation are a real but *different* artifact (see the `ghidra` and `reva` packs' own struct-inference guidance) -- not an entity-relationship diagram of a database schema. Do not attempt this mode. |
| UI surfaces (`U-`) | **NOT SUPPORTED** | Assumes a DOM/component tree, routes, or a TUI/CLI framework's widget registrations. Ghidra's decompilation of a native binary has no equivalent structure to enumerate. Do not attempt this mode. |
| Interaction patterns (`P-`) | **NOT SUPPORTED** | Assumes ARIA roles, JSX composition shape, and CSS class conventions. None of these exist below the level of a rendered UI; a stripped binary has nothing for this mode to read. Do not attempt this mode. |

If the user asks for "a full architectural analysis" (upstream's default: all eight modes), run
only Integrations, Control flow, Data flow, and Failure modes, and say plainly in the synthesis
README that Information architecture, Data model, UI surfaces, and Interaction patterns were
skipped and why -- do not silently produce a four-mode report labeled as complete.

## Strict citation policy -- address, not line

Read `references/citation-protocol.md` before authoring any diagram; it is retargeted in full
(the load-bearing rewrite this pack exists for). Summary of the retarget:

- Every node carries a callout ID and a citation in the form `<function-or-symbol>@<address>`
  (e.g. `ai_decrypt_payload@0x00401234`), not `path:line`.
- Every edge carries a citation: the address of the call site, from `list_xrefs` or
  `disassemble`, not an import-statement line.
- "Absence claims grep first" becomes "absence claims: check `search_strings`,
  `search_symbols_by_name`, `list_imports`, and `list_exports` first" -- there is no source tree
  to grep.
- "Quoted code is exact" now means the evidence string is the verbatim decompiled-C line (from
  `decompile_function`) or disassembly instruction (from `disassemble`) as the tool returned it --
  paraphrase still counts as fabrication.

## Workflow

The eight-phase shape is unchanged; what each phase reads and how citations verify are retargeted.

### 1. Scope

Establish:

- **Target**: the binary (or a named function set already identified by `reva-binary-triage` /
  `reva-deep-analysis` / `ghidra-iterative-re`) -- not a repo path or subtree.
- **Modes**: which of the four supported modes (default: Integrations + Control flow + Data flow
  + Failure modes if the user said "full analysis" -- never the four unsupported ones).
- **Output root**: `docs/architecture/<YYYY-MM-DD>/` -- create now if missing.
- **Binary identity**: call `list_project_binary_metadata` for format, architecture, and entry
  point. This replaces upstream's `.codanna/` availability check -- there is no equivalent local
  index to probe for on this host; symbol resolution always goes through `pyghidra-mcp` (see
  Phase 4).

### 2. Read prior artifacts (load the spine)

Upstream's "doc spine" (README, CHANGELOG, CLAUDE.md) does not exist for a stripped binary.
Substitute: prior triage/deep-analysis output for *this* binary, if any exists in the current
conversation or session --

- `reva-binary-triage`'s `TodoWrite` task list and returned report.
- `reva-deep-analysis`'s returned findings, and any `ai_`-prefixed renames or `ANALYSIS:`/
  `TODO:`/`ASSUMPTION:`-tagged `set_comment` calls it made (per that skill's Tracking Phase).
- `ghidra-iterative-re`'s prior session notes, if the user references one.

**This host has no comment-search tool** (the same gap `reva-deep-analysis`'s Limitations
documents for `pyghidra-mcp`) -- there is no mechanical way to pull all prior `set_comment` tags
back out of the database. Treat "prior artifacts" as whatever is already in front of you (this
conversation's context, or what the user pastes), not as a query you can run. If nothing exists,
mark this in the synthesis README exactly as upstream's greenfield case: "No prior analysis spine
for this binary -- every finding here is new." Skip authoring `docs-inventory.txt`/`doc-map.md` --
there are no in-tree docs to inventory; note in the synthesis README instead which prior-session
artifacts (if any) fed this run.

### 3. Dispatch sub-agents (parallel, primed with prior artifacts)

Read `references/subagent-dispatch.md`, retargeted in full: the tool substrate each sub-agent
uses is now the declared `mcp__pyghidra-mcp__*` tools above, not `grep`/`Read`. The output
contract's `citation` field is `<function-or-symbol>@<address>`, and `classification` compares
each finding against prior-artifact context (a `reva-binary-triage` todo, a `reva-deep-analysis`
finding) rather than a doc claim -- `confirms`/`drift`/`gap`/`extends` keep their meaning with
"the spine" now meaning "prior session artifacts" rather than "in-tree docs."

Dispatch in a single message with parallel `Agent` tool calls, one per mode, as upstream requires.
Never with `team_name`.

### 4. Verify (orchestrator)

Read `references/verification-protocol.md`, retargeted in full. In place of codanna/grep/Read:

- Resolve every cited symbol via `search_symbols_by_name` (existence), `decompile_function` or
  `disassemble` (content at the cited address), and `list_xrefs` (edge citations).
- Absence claims ("no error handler", "doesn't validate X") are checked with
  `search_strings`/`search_symbols_by_name`/`list_imports`/`list_exports` before being recorded,
  never asserted from a sub-agent's un-verified negative.
- Evidence strings must match the tool's returned decompiled-C line or disassembly instruction
  verbatim -- same substring-match discipline upstream's Pass 1 describes, just against tool
  output instead of a file read.

### 5. Render diagrams

Unchanged. Author `<mode>/<diagram>.mmd` per `references/mermaid-conventions.md` (upstream,
format/syntax content -- format conventions do not depend on what a citation looks like). Run
`bash scripts/render.sh <report-dir>/ --style corporate`.

### 6. Author mode reports

Per `references/report-template.md` (upstream shape; the "doc reference" collapsed section
becomes a "prior-artifact reference" collapsed section citing `reva-*`/`ghidra-*` findings
instead of an in-tree doc). Citations throughout are `function@address`.

### 7. Synthesize

Per `references/synthesis-readme.md` (upstream shape). Explicitly list the four unsupported
modes and why, per `## Mode support on this host` above, in the Scope section.

### 8. Compile HTML (automatic)

Unchanged: `bash scripts/render.sh ... && bash scripts/compile-html.sh ...`. Neither script reads
or depends on citation format.

### Optional hand-off

Upstream's hand-off targets (`doc-maintenance`, `wiring-audit`, `doc-claim-validator`,
`test-review`) are source-tooling skills this host does not vendor. If the user wants to act on a
gap finding, say so plainly and suggest `reva-deep-analysis` for a specific follow-up question
instead of naming a skill that does not exist here. Do not auto-invoke anything.

### Shareable artifacts

Unchanged from upstream -- `render.sh`/`compile-html.sh`/`compile-pdf.sh` operate on `.mmd`/`.md`
files generically and do not depend on citation format. See upstream's own flag reference below
(unmodified, still accurate):

- `--style {corporate|blueprint}` -- visual style.
- `--theme {light|dark}` -- initial theme.
- `--banner <path>`, `--repo-root <path>`, `--out <path>`.
- PDF only on explicit request: `bash scripts/compile-pdf.sh docs/architecture/<date>/`.

## Output layout

Unchanged from upstream (`docs/architecture/<date>/README.md`, per-mode subdirectories,
`.html`/`.pdf`) except there is no `docs-inventory.txt` (see Phase 2) and `doc-map.md` becomes an
optional prior-artifact note rather than a required Phase-2 output.

## Resources

- `references/citation-protocol.md` -- **retargeted**: address-based citation rules.
- `references/verification-protocol.md` -- **retargeted**: pyghidra-mcp-based verification passes.
- `references/subagent-dispatch.md` -- **retargeted**: pyghidra-mcp tool substrate per mode.
- `references/mode-integrations.md` -- **retargeted**: imported/exported-API signal catalog.
- `references/mermaid-conventions.md` -- upstream, format/syntax only; see its "On this host" note.
- `references/report-template.md`, `references/synthesis-readme.md`, `references/doc-map.md` --
  upstream shape; see each file's "On this host" note for the doc-spine -> prior-artifact swap.
- `references/mode-{information,data-flow,ui-surfaces,interaction-patterns,data-model,control-flow,failure-modes}.md`
  -- upstream signal catalogs; see each file's "On this host" note. Four are marked NOT SUPPORTED
  (do not use); three (control-flow, data-flow, failure-modes) are conceptually applicable but
  their listed signals were not rewritten -- ground findings in pyghidra-mcp tool output and the
  mode's *diagram shape*, not the listed source-language signals.
- `scripts/render.sh`, `scripts/compile-html.sh`, `scripts/compile-pdf.sh` -- upstream, unmodified,
  generic mermaid/pandoc rendering with no citation-format dependency.
- `scripts/verify-citations.sh` -- **does not apply on this host** (see its own header comment and
  `## Limitations` below) -- it greps a report for `path:line` patterns and checks them against
  files on disk; an address-based citation has no file to check against. Verification here is the
  orchestrator's Phase 4 (mechanical, against `pyghidra-mcp`), not this script.
- `assets/template.html`, `assets/report.css`, `assets/mermaid-config.json` -- upstream, unmodified.

## Limitations

Adapted from `NickCrew/Claude-Cortex`'s `architectural-analysis` skill (one skill vendored out of
that repo's much larger multi-skill collection; only this directory was vendored -- see
`re-agent.config.json`'s `arch` pack).

- **Four of eight modes are NOT SUPPORTED and must not be run** -- information architecture, data
  model, UI surfaces, interaction patterns. See `## Mode support on this host`. Their reference
  files (`mode-information.md`, `mode-data-model.md`, `mode-ui-surfaces.md`,
  `mode-interaction-patterns.md`) are vendored pristine and carry their own "NOT SUPPORTED" banner;
  do not follow their prose.
- **Three modes (control-flow, data-flow, failure-modes) are conceptually applicable but their
  reference files were not rewritten** -- only banner-noted. Their listed signal catalogs
  (async/await, ORM, framework lifecycle hooks, `try`/`except` syntax) are source-specific and do
  not port; use the mode's diagram *shape* with evidence gathered from `decompile_function`,
  `list_xrefs`, `gen_callgraph`, and `search_strings` instead.
- **`scripts/verify-citations.sh` does not run against this pack's output.** It is a `path:line`
  file-existence checker; address citations have nothing on disk for it to check. Phase 4's
  mechanical verification against `pyghidra-mcp` is the only citation check that applies here.
- **No prior-artifact query mechanism.** `pyghidra-mcp` has no comment-search tool, so Phase 2's
  "spine" is whatever prior-session context is already available, not something this skill can
  fetch on demand. See Phase 2.
- **Sub-agent tool access.** Dispatched sub-agents (`Explore`/`general-purpose`, per
  `subagent-dispatch.md`) need the same `mcp__pyghidra-mcp__*` tools this skill declares in order
  to gather evidence -- confirm the harness grants dispatched sub-agents the parent skill's
  declared tools before relying on their returns; this was not independently verified against a
  live dispatch on this host.
- **`Bash`, `Write`, `Agent` are broader than any single phase needs** -- `Bash` runs only the
  bundled render/compile scripts, `Write` only authors reports/diagrams/JSON under
  `docs/architecture/`, and `Agent` only dispatches the per-mode sub-agents in Phase 3. Flagging
  for the user's sign-off per this host's standing rule that `allowed-tools` is a statement of
  intent, not a runtime fence.
