# Verification Protocol (binary-graph adaptation)

## On this host

Retargeted in full. Upstream's orchestrator verifies against source files via `codanna`/`grep`/
`Read`; this host has none of those for a stripped binary. Every pass below verifies against
`pyghidra-mcp` tool output instead. The mechanical discipline -- verify before rendering, log
every discard -- is unchanged.

The orchestrator's mechanical pass over candidate findings returned by sub-agents. This is what
enforces the citation policy. Sub-agents fabricate at predictable rates; verification is the
structural safeguard.

## Inputs

A list of candidate findings from one or more sub-agents, each shaped per `subagent-dispatch.md`:

```yaml
- callout_id: X-3
  label: "ai_send_beacon calls WinHttpSendRequest"
  citation: ai_send_beacon@0x00401810
  evidence: "WinHttpSendRequest(hRequest,0,0,0,0,0,0);"
  relations:
    - to: X-1
      kind: calls
      citation: ai_send_beacon@0x00401824
  confidence: high
```

## Pass 1 -- Symbol resolution

For each finding's `citation` (and each `relations[*].citation`):

1. **Confirm the symbol exists** at the cited address with `search_symbols_by_name` (by name) or
   `list_project_binary_metadata`/`gen_callgraph` (to confirm the address falls within a known
   function). There is no `.codanna/`-equivalent local index on this host -- every resolution
   goes through `pyghidra-mcp`, live.
2. **Fetch the content at the citation.** Use `decompile_function` for a decompiled-C citation, or
   `disassemble` for an instruction-level citation. Re-request the specific function/address, do
   not reuse a stale earlier response.
3. **Match evidence to content.** The `evidence` string must appear verbatim in the tool's
   returned text for that citation. Trim leading/trailing whitespace before comparing -- match on
   substring, not equality, same as upstream.

If any of these fail, the finding is **discarded** and logged.

## Pass 2 -- Absence claims

A finding whose label or evidence asserts absence (`"no error handler"`, `"missing validation"`,
`"doesn't call WinHttpSendRequest"`) is checked separately:

1. Construct a check for the asserted-missing symbol: `search_strings` for a text pattern,
   `search_symbols_by_name` for a name pattern, or `list_imports`/`list_exports` for an
   API/symbol that should appear in the table if present.
2. Check across the binary as a whole, not just the function the sub-agent looked at -- sub-agents
   narrow context aggressively and over-fire on absence, same failure mode upstream documents for
   source-tree absence claims.
3. If the symbol turns up, the finding is discarded. Log it as "absence claim rejected: `<symbol>`
   exists at `<address>` (per `<tool>`)".

## Pass 3 -- Synthesized validation

Unchanged in mechanism from upstream:

1. Confirm a `synthesized_justification` field exists and is non-trivial (not just "no single
   owner").
2. Confirm at least two contributing functions are named in the justification.
3. Cite each contributing function at a representative address.
4. Track the synthesized count and the verified-cited count for the mode. After all findings are
   processed, compute synthesized share:

```
synthesized_share = synthesized_count / (synthesized_count + cited_count)
```

Cap for every supported mode on this host: **0.20**. Upstream's raised 0.35 cap was specific to
interaction patterns, which is NOT SUPPORTED here -- there is no per-mode exception on this host.

If `synthesized_share` exceeds 0.20, decide before rendering:

- **Promote**: pick the most-canonical contributing function for each weakest synthesized node
  and re-classify as cited.
- **Drop**: remove weakest synthesized nodes until under cap.
- **Escalate**: tell the user the synthesized share is high and ask whether to proceed, raise the
  cap, or rescope. A high synthesized share on a binary is a real signal -- often that the
  functions you decompiled don't yet cover enough of the behavior to ground the concept.

## Pass 4 -- Edge consistency

Unchanged: for each verified node, walk its `relations`. Each relation's `to` must be the callout
ID of another verified node. Dangling edges (pointing to discarded or non-existent IDs) are
dropped, and the drop is logged.

## Outputs

Two artifacts feed the rendering phase, unchanged:

1. **Verified findings** -- survivors of all four passes, ready to commit to mermaid + report.
2. **Discard log** -- every dropped finding with reason. Goes verbatim into the report's
   "Verification log" section.

## Tooling preference

When checking citations, use in this order:

1. **`search_symbols_by_name`** -- for symbol-level existence questions (replaces upstream's
   codanna-first preference; there is no local index to prefer over a live query here).
2. **`decompile_function` / `disassemble`** -- for fetching the content at a specific citation.
3. **`search_strings` / `list_imports` / `list_exports`** -- for absence checks and bulk
   symbol/string lookups across the whole binary.

Do not use the `Explore` agent or any sub-agent for verification. Verification is the
orchestrator's job; delegating it re-introduces the fabrication risk it exists to defeat -- same
rule as upstream, restated because it does not depend on what kind of target is being analyzed.

## Performance

Upstream's per-finding timing figures (codanna ~200ms, grep ~500ms, Read ~50ms) do not carry over
-- this adaptation has not measured `pyghidra-mcp` tool-call latency on this host. Budget
generously and expect verification, not evidence-gathering, to be the bottleneck, same as
upstream's own conclusion. Skipping verification to save time is not acceptable here either --
fabricated nodes cost days of debugging confusion downstream, same as upstream.

## When verification cannot run

If `pyghidra-mcp` is unreachable (server down, binary not imported into the project), this skill
cannot produce trustworthy diagrams. Tell the user:

> Architectural analysis with strict citations requires a live `pyghidra-mcp` connection to this
> binary. Verification cannot run without it. Confirm the server is running and the binary is
> imported (`list_project_binaries`), or pause this analysis.

Do not produce a diagram with un-verified citations. That's the failure mode this skill exists to
prevent -- unchanged from upstream.
