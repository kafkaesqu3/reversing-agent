---
name: tob-trailmark
description: "Applies Trail of Bits' Trailmark graph engine (blast radius, taint propagation, privilege-boundary detection, entry-point reachability) to a stripped binary analyzed through the pyghidra-mcp MCP server, by assembling a Trailmark binary-graph JSON from decompile_function/list_xrefs/gen_callgraph output and importing it with engine.augment_binary() -- Trailmark's own binary-augmentation API, not a source parse. Use after reva-binary-triage or reva-deep-analysis has identified a function set worth graph-level structural analysis (blast radius, taint reachability, privilege boundaries) on a binary with no available source. Trailmark itself is a separate PyPI tool this skill drives via `uv run`, not part of this host's pinned MCP server catalog."
license: CC-BY-SA-4.0
allowed-tools:
  - mcp__pyghidra-mcp__list_project_binary_metadata
  - mcp__pyghidra-mcp__decompile_function
  - mcp__pyghidra-mcp__list_xrefs
  - mcp__pyghidra-mcp__gen_callgraph
  - Bash
  - Write
  - Read
---

# Trailmark (binary-graph adaptation)

## Overview

Upstream Trailmark parses a multi-file **source** tree into a directed graph of functions,
classes, and calls, then runs four structural passes over it (blast radius, entry-point
reachability, privilege boundaries, taint propagation). This host analyzes **stripped
binaries** through `pyghidra-mcp` -- there is no source tree to parse, and Trailmark ships no
disassembler of its own.

What still applies: Trailmark 0.4.0+ ships `engine.augment_binary()`, an API built exactly for
this situation -- it imports an external **binary-analysis graph** (a small, documented JSON
shape: an `artifact` object, a `functions` list, a `calls` list) and merges it into a graph the
rest of Trailmark's query and pre-analysis surface already understands. Upstream's own words:
*"Trailmark connects it to source nodes when possible; it does not disassemble binaries
itself."* This skill is the disassembly-to-JSON bridge upstream expects the caller to build --
sourced from `pyghidra-mcp`'s `decompile_function`, `list_xrefs`, and `gen_callgraph` tools
instead of a source parser.

**What this buys you**: blast-radius ranking, entry-point-reachability queries, and the
taint/privilege-boundary subgraphs, computed over the *specific functions you have already
decompiled* -- not the whole binary. It is a **partial, function-set-scoped graph**, built one
triage/deep-analysis session at a time, not an automatic whole-binary call graph. See
`## Limitations` before treating any pass's output as exhaustive.

## Not part of this host's reviewed MCP server surface

`trailmark` is a PyPI package (`uv tool install trailmark`), not an MCP server -- it has no
entry in `re-agent.config.json`'s `mcpServers[]` and no entry in `data/tool-catalog.json`. The
only MCP server this skill drives is `pyghidra-mcp`, declared above. Installing and running
Trailmark itself is local tool use (`Bash`), exactly as upstream's own Installation section
already required on any host.

## Installation

**MANDATORY:** If `trailmark` is not found, install the CLI before doing anything else:

```bash
uv tool install trailmark
```

A tool install provides the CLI only -- it does not make `import trailmark` resolvable. Run the
Python snippets in this skill with `uv run --with trailmark python -`; that, not installation, is
the fix for an import error or `ModuleNotFoundError` in a snippet.

**DO NOT** fall back to "manual verification" or eyeballing decompiled output as a substitute for
running Trailmark's structural passes once you have a function set worth graphing. If
installation fails, report the error to the user instead of silently abandoning the graph step.

## Version Gate

`engine.augment_binary()` requires **Trailmark 0.4.0 or newer** -- binary graph augmentation is a
v0.4+ feature; it does not exist on 0.2.x/0.3.x installs. Check before relying on it:

```bash
trailmark --version 2>/dev/null || uv run trailmark --version 2>/dev/null
```

Compare the reported version numerically. If it is older than `0.4.0`, this skill's binary-graph
workflow cannot run -- report that to the user rather than attempting a source-directory parse of
Ghidra output (see `## Limitations`).

## Building a binary graph on this host

This skill does not triage a binary itself -- start from a function set `reva-binary-triage`,
`reva-deep-analysis`, or `ghidra-iterative-re` has already flagged as worth graphing. Then:

### 1. Identify the artifact

Call `list_project_binary_metadata` for the binary. Its reported format, architecture, and entry
point become the JSON's `artifact` block (`key`, `path`, `architecture`; a `hash` field is
optional and may be omitted if you have not independently computed one).

### 2. Gather each function of interest

For every function in your set, call:

- `decompile_function` -- pseudo-C for the function body. Read it for call sites you must
  represent as edges; do not invent a call that isn't visible in the decompilation or in
  `list_xrefs`.
- `list_xrefs` (direction `"to"` and `"from"`) -- confirms the immediate callers/callees Ghidra
  itself resolved for this function, independent of what the decompiler's C view shows. Prefer
  `list_xrefs` over parsing call syntax out of decompiled text for edge extraction: it is Ghidra's
  own resolved reference table, not a text scrape of pseudo-C.
- `gen_callgraph`, once per session (not once per function) -- a broader edge set you can
  cross-check individual `list_xrefs` results against, and a source of edges for functions in
  your set that call each other but that you have not individually decompiled.

Record each function's name/symbol and address as reported by these tools. Do not guess an
address; a function you cannot resolve to a concrete address from tool output does not get a
`functions[]` entry.

### 3. Assemble the Trailmark binary-graph JSON

Shape (documented in Trailmark's own `augment_from_binary_graph`; unknown fields are ignored,
nothing here is invented):

```json
{
  "artifact": { "key": "sample.exe", "path": "sample.exe", "architecture": "x86_64" },
  "functions": [
    { "id": "ai_decrypt_payload", "symbol": "ai_decrypt_payload", "address": 4198400 },
    { "id": "FUN_00402010", "symbol": "FUN_00402010", "address": 4202512 }
  ],
  "calls": [
    { "source": "ai_decrypt_payload", "target": "FUN_00402010",
      "confidence": "inferred", "address": 4198512 }
  ]
}
```

Notes, verified against Trailmark's binary-graph importer:

- `functions[].id`/`symbol`/`name` and `address`/`rva` are all valid reference keys; `calls[]`
  entries resolve `source`/`target` against whichever of those keys matches. Use the same symbol
  string you used in `functions[]` -- if you renamed the function in Ghidra with the mandatory
  `ai_` prefix (see `## Renames feed this graph too`), use the renamed, `ai_`-prefixed symbol
  here, not the pre-rename `FUN_...` name, so the graph reflects the database you are actually
  working from.
- **`confidence` is not decorative, and it is mandatory on every `calls[]` entry -- do not omit
  it.** Verified against Trailmark's own importer (`analysis/binary.py`'s `_confidence()`): an
  **omitted field defaults to `"certain"`**, not `"inferred"` -- the exact opposite of the safe
  default you'd expect, and the one input shape that silently launders every unverified edge into
  a confident claim. Always write the field explicitly. Set `"certain"` only for a direct,
  statically-resolved call you can see at a fixed address in disassembly or decompilation. Set
  `"inferred"` for anything from `list_xrefs`/`gen_callgraph` you have not individually
  re-verified in disassembly -- Ghidra's own call-target resolution is not infallible, especially
  through function pointers, vtables, or PLT/import stubs. Never mark an indirect or
  computed-target call `"certain"`, and never rely on leaving the field out.
- A `target` that resolves to nothing in your `functions[]` list becomes an external proxy node
  (`proxy.external:<symbol>`) automatically -- this is Trailmark's own behavior, useful for
  marking "calls something outside the set you decompiled" without inventing a `functions[]` entry
  for code you have not looked at.
- Write the JSON with the `Write` tool to a scratch path under your report/output directory (e.g.
  `docs/architecture/<date>/binary-graph.json` if this skill is used alongside `arch`'s output
  layout, or any scratch path you choose) -- `augment_binary()` reads it from disk by path, it does
  not accept the JSON inline.

### 4. Import it and query

```python
from trailmark.models.graph import CodeGraph
from trailmark.query.api import QueryEngine

# An empty graph -- every field on CodeGraph() defaults, so this is a
# valid, fully empty starting point. There is no separate
# "from_binary" constructor; augment_binary() populates an existing
# (possibly empty) engine.
engine = QueryEngine.from_graph(CodeGraph())
result = engine.augment_binary("docs/architecture/<date>/binary-graph.json")
print(result)  # {"artifact": ..., "binary_nodes": N, "call_edges": N, "external_proxies": N, ...}
```

Then query directly -- `callers_of()`, `callees_of()`, `ancestors_of()`, `reachable_from()`,
`paths_between()`, `to_json()`, and `preanalysis()` all operate on node IDs and call edges, which
your binary graph has regardless of node origin:

```python
engine.callers_of("ai_decrypt_payload")
engine.callees_of("ai_decrypt_payload")
engine.reachable_from("ai_decrypt_payload")
engine.ancestors_of("FUN_00402010")
```

## Pre-Analysis on a binary-only graph

`engine.preanalysis()` runs the same four passes documented in
`references/preanalysis-passes.md` (blast radius, entry points, privilege boundaries, taint) --
the mechanism is unchanged; only the input differs. One real gap:

**Entry points do not auto-populate.** `QueryEngine.from_directory()` calls Trailmark's
source-language entrypoint detector (route decorators, `main()` conventions, etc.) automatically;
`QueryEngine.from_graph()` -- the constructor this workflow uses -- does not call it, and that
detector would not recognize binary nodes regardless. If you want entry-point-reachability or
taint numbers anchored on the binary's real entry point, annotate it yourself before calling
`preanalysis()`:

```python
from trailmark.models.annotations import EntrypointKind, EntrypointTag, TrustLevel

# CodeGraph.entrypoints is keyed by node id, not by bare symbol name -- unlike
# callers_of()/reachable_from() above, which resolve a bare name through
# find_node_id() for you. A binary node's id is bin.<artifact_key>:<symbol>
# (see _binary_node_id in analysis/binary.py), not the symbol alone. Resolve it
# through the same public lookup those query methods use, rather than guessing
# or reconstructing the id format by hand:
node_id = engine._store.find_node_id("<entry-function-symbol>")
assert node_id is not None, "entry function not found in the graph -- check the symbol"
engine._store._graph.entrypoints[node_id] = EntrypointTag(
    kind=EntrypointKind.USER_INPUT, trust_level=TrustLevel.UNTRUSTED_EXTERNAL)
```

**A bare symbol string as the dict key will *not* work here, even though it works one line up
in `callers_of()`/`reachable_from()`.** Those methods route through `find_node_id()`
internally; `entrypoints` is a plain dict with no such resolution, so a bare-symbol key
registers silently under the wrong key -- no error, but `entrypoint_reachable`,
`privilege_boundary`, and `tainted` all stay empty, which looks identical to "nothing wrong,
no entrypoints matter here" rather than "this step was skipped." Always resolve `node_id`
first, exactly as shown.

`kind` is required (no default); pick the closest fit from `EntrypointKind`
(`USER_INPUT`/`API`/`DATABASE`/`FILE_SYSTEM`/`THIRD_PARTY`) -- for a binary's real entry point,
`USER_INPUT` or `API` are the usual fits. This reaches into the engine's internal graph directly
(there is no public `add_entrypoint()` method as of this writing) -- treat it as a workaround, not
a documented API, and re-verify both field names against the installed Trailmark version's actual
`EntrypointTag`/`TrustLevel`/`EntrypointKind` definitions before relying on it.
Without this step, `preanalysis()` still computes blast radius (pure graph topology, entrypoint-
independent) but the `entrypoints`, `entrypoint_reachable`, `privilege_boundary`, and `tainted`
subgraphs will all be empty.

## Reachability is not taint

Preserved verbatim from upstream, because it is the reason this pack was chosen and it applies
here without qualification:

> This is call-graph reachability used as a coarse taint signal, not interprocedural data-flow
> analysis. Membership in `tainted` means an untrusted entrypoint can *reach* the node, not that
> attacker-controlled data demonstrably flows into it — verify data flow manually before claiming
> it.

On this host that caution compounds: even the *reachability* edges feeding this graph are
Ghidra's inferred call graph (`list_xrefs`/`gen_callgraph`), not source-verified calls, and most
of them carry `confidence: "inferred"` rather than `"certain"` (see step 3 above). A path
`entrypoint_paths_to()` reports here is reachable-per-Ghidra's-resolution *and* not proven to
carry attacker-controlled data -- two independent reasons to verify by hand, not one.

## Renames feed this graph too

If triage or deep-analysis has renamed functions in the Ghidra database, every renamed symbol
carries the mandatory `ai_` prefix (the same convention the `ghidra` and `reva` packs establish
for this same `pyghidra-mcp` server). Use the current, possibly `ai_`-prefixed name in this
graph's `functions[]`/`calls[]` entries -- the graph should describe the database as it now
stands, not a stale pre-rename snapshot.

## Query Patterns

See `references/query-patterns.md` for the query API reference (unchanged by this adaptation --
it documents the same `QueryEngine` methods this skill calls above) and
`references/preanalysis-passes.md` for the four pre-analysis passes in detail.

## Limitations

Adapted from `trailofbits/skills`' `trailmark` skill. Upstream's `trailmark` plugin ships 14
skills; only this one core skill was vendored here at all -- the other 13 were never copied
into `vendor/skills/tob/` and have no entry of any kind in `re-agent.config.json`'s `tob` pack
(one `skills[]` entry, `tob-trailmark`, and nothing else). See the next bullet.

- **Partial graph, not a whole-binary call graph.** This skill's graph contains only the
  functions you explicitly fed it through steps 1-3. Blast radius, reachability, and taint numbers
  are relative to *that set plus whatever `gen_callgraph`/`list_xrefs` edges point outside it*
  (via external proxy nodes) -- they are not whole-binary metrics. Upstream's own `from_directory`
  workflow parses an entire source tree in one pass; nothing here reproduces that for a binary.
- **No automatic entry-point detection.** See `## Pre-Analysis on a binary-only graph` above.
- **No verified JSON field mapping from pyghidra-mcp's raw tool output.** The `functions[]`/
  `calls[]` shape above is Trailmark's own documented binary-graph schema (verified against
  `trailofbits/trailmark`'s `src/trailmark/analysis/binary.py`); the mapping from a given
  `list_xrefs`/`gen_callgraph`/`decompile_function` response onto that schema is this
  adaptation's own construction, written from the tool *names* in `data/tool-catalog.json`, not
  from a captured live response. Confirm the actual field names in your `pyghidra-mcp` tool
  results before assuming they match what step 2/3 above describe, and treat any mismatch as a
  reason to adjust the mapping, not the schema.
- **Trailmark's source-language features are all out of scope here.** Language detection,
  `.trailmark/links.toml` cross-language links, SQL schema parsing, type/generic queries, and
  `diff_against()` (two source snapshots) all assume source nodes this workflow never creates.
  Do not invoke them against a binary-only graph.
- **Upstream's other 13 `trailmark`-plugin skills were deliberately not vendored at all** --
  not vendored-and-disabled, simply absent. They covered source-tree workflows this host
  cannot run anyway (mutation testing, SARIF/CodeQL/Semgrep integration, git-diff review
  gates, formal-verification spec generation), so narrowing to this one skill lost no
  capability this host could have used. A cross-reference to one of them elsewhere in this
  pack's remaining upstream text names a skill that is not installed here -- for example,
  `references/preanalysis-passes.md`'s pristine "before downstream skills (genotoxic,
  diagramming-code) consume it" refers to two skills that do not exist on this host; treat
  any such mention as inert, not as a pointer to something you can invoke.
