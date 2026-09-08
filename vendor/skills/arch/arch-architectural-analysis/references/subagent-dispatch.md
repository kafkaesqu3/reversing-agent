# Sub-agent Dispatch (binary-graph adaptation)

## On this host

Retargeted in full. Only four of upstream's eight modes are dispatched here -- see `SKILL.md`'s
mode-support table. The tool substrate each sub-agent uses is `pyghidra-mcp`, not `grep`/`Read`
over a source tree.

How the orchestrator delegates per-mode evidence-gathering to sub-agents. Designed for parallel
execution, structured returns, and downstream verification.

## Agent type / model matrix

| Mode | Agent type | Model | Why |
|---|---|---|---|
| Integrations | `Explore` | haiku | Import/export/string enumeration via `list_imports`/`list_exports`/`search_strings`; pattern-driven, no deep reasoning needed |
| Data flow | `general-purpose` | sonnet | Tracing data across `decompile_function`/`list_xrefs` calls requires reasoning about what counts as a meaningful transform |
| Control flow | `general-purpose` | sonnet | Recognizing a state machine or thread-lifecycle shape in decompiled/disassembled output needs judgment, not pattern matching |
| Failure modes | `general-purpose` | sonnet | Distinguishing a real error path from happy-path control flow in decompiled output needs judgment |

Information architecture, data model, UI surfaces, and interaction patterns are **not
dispatched** -- they are NOT SUPPORTED on this host (see `SKILL.md`). Do not add sub-agent calls
for them.

Justification for the split, carried over from upstream: `Explore` is read-only and optimized for
fast pattern matching against tool output (upstream: file excerpts; here: `list_imports`/
`list_exports`/`search_strings` results). Integrations fits that shape. The three reasoning modes
need to read full decompiled/disassembled output and infer structure, which `general-purpose`
handles better.

## Dispatch rules

Unchanged from upstream:

1. **One-shot, parallel.** Issue all sub-agent calls in a single message with multiple `Agent`
   tool blocks. Do not chain.
2. **No `team_name`.** Always use bare `Agent` calls.
3. **One sub-agent per mode.** Do not dispatch multiple sub-agents per mode.
4. **Pass scope explicitly.** Always include the target -- the binary's identity
   (`list_project_binary_metadata` output) and, if triage already narrowed it, the specific
   function set to focus on. "The whole binary" is a valid scope but produces more findings than a
   pre-narrowed function set.
5. **Return findings only, not diagrams.** Sub-agents enumerate; the orchestrator authors mermaid.

## Output contract (prior-artifact-led classification)

Sub-agents classify each finding against **prior-artifact context** -- upstream's "doc spine" is
now whatever `reva-binary-triage`/`reva-deep-analysis`/`ghidra-iterative-re` output (or the user's
own prior notes) is already in front of the orchestrator (see `SKILL.md` Phase 2; there is no
query mechanism to fetch more of it). The orchestrator passes the relevant prior-artifact text in
the prompt; the sub-agent gathers evidence from `pyghidra-mcp` and decides whether it confirms,
drifts from, or extends that prior context, or is a wholly new gap.

YAML block, one entry per finding:

```yaml
- callout_id: <PREFIX>-<N>           # e.g., X-1, C-4 -- N starts at 1 per mode
  label: <short human label>
  citation: <symbol>@<address>
  evidence: <verbatim decompiled-C line or disassembly instruction>
  classification: confirms | drift | gap | extends
  prior_ref: <which reva-*/ghidra-* finding this checks against, or null if none>
  prior_claim: <quoted or paraphrased prior finding being checked; null if classification=gap>
  notes: <one-line explanation -- required for drift, optional otherwise>
  relations:
    - to: <callout_id>
      kind: calls | reads | writes | imports | exports | jumps_to | etc.
      citation: <symbol>@<address>
  confidence: high | medium | synthesized
  synthesized_justification: <required if confidence=synthesized; names >=2 contributing functions>
```

### Classification semantics

Unchanged in shape from upstream, "doc" replaced by "prior artifact":

- **confirms** -- pyghidra-mcp evidence matches a prior finding. Default when prior context covers
  the territory.
- **drift** -- a prior finding claimed X, current evidence shows Y (e.g., a rename or re-analysis
  changed what's visible). `notes` MUST quote both. Always in the report's drift section, never
  collapsed.
- **gap** -- the binary does something no prior artifact covers. `prior_ref`/`prior_claim` are
  null. **Gaps drive the synthesis README's "Undocumented behaviors" section.**
- **extends** -- adds detail a prior finding didn't claim but doesn't contradict.

### Volume target

Unchanged from upstream: prior-artifact-led runs should produce fewer findings than a from-scratch
enumeration, because confirmed-on-spine territory yields one finding per prior claim, not one per
function. If a sub-agent returns 100+ findings against 10 prior claims, it's over-enumerating.

If a sub-agent returns prose without citations, treat the result as judgment-only -- discard the
specifics and re-dispatch.

## Prompt template (prior-artifact-led)

The prompt for each sub-agent has the same seven sections as upstream, with **Doc spine** renamed
to **Prior artifacts**:

```
[Mode-specific intro from references/mode-<mode>.md]

# Scope
[The binary's identity from list_project_binary_metadata, and either "the whole binary" or a
specific function set already identified by prior triage/deep-analysis]

# Prior artifacts

The following prior findings (if any) are relevant to this mode. The orchestrator has already
gathered them from this conversation's context; your job is to gather fresh evidence from
pyghidra-mcp, confirm or contradict them, and surface gaps.

[For each relevant prior finding, paste it or summarize it. Example:

  ## reva-binary-triage finding: suspicious import WinHttpSendRequest

  > Flagged in the Import Analysis section: WinHttpSendRequest, WinHttpOpen imported;
  > referenced from ai_send_beacon (0x00401800-ish, per triage's callgraph-derived count)

If the mode has no prior artifact:

  ## No prior artifact for this mode.
  Treat every finding as classification=gap. The orchestrator will surface this in the
  synthesis README.
]

# Task
Gather evidence from pyghidra-mcp for this mode (tools: [list the specific mcp__pyghidra-mcp__*
tools this mode uses, from SKILL.md's allowed-tools]). For each prior claim relevant to this mode:
- Confirm it against fresh pyghidra-mcp output and emit a `confirms` finding.
- If fresh evidence disagrees, emit a `drift` finding with both citations.
- For territory no prior artifact covers but that you find architecturally significant, emit a
  `gap` finding.

Do NOT re-derive territory a prior artifact already covers cleanly -- cite it and move on.

[Mode-specific signals to look for from references/mode-<mode>.md, read with the "On this host"
banner in mind -- most of that file's listed signals are upstream source-language patterns that
do not apply; ground findings in pyghidra-mcp tool output instead]

# Output contract
Return a YAML block using exactly this shape:

[Paste the output contract block from this file]

Notes:
- callout_id starts at <PREFIX>-1 and increments
- citation must be <symbol>@<address>
- evidence is verbatim decompiled-C or disassembly text, no paraphrase
- Absence claims ("no X handler") -- check search_strings/search_symbols_by_name/list_imports/
  list_exports first; discard if X exists
- Drift findings MUST quote both the prior claim and the fresh evidence in `notes`
- Gap findings MUST justify themselves: why is this worth flagging?
- Synthesized findings allowed but require >=2 contributing functions in justification

# Verification expectation
The orchestrator will mechanically re-verify every citation against pyghidra-mcp. Accuracy here
directly shapes what readers act on.

# Format reminder
Return only the YAML block. No prose preamble or postamble.
```

## Parallel call shape (orchestrator side)

```
[Single message containing 4 Agent tool blocks, in parallel]

Agent({subagent_type: "Explore", model: "haiku", description: "Integrations enum",
  prompt: <integrations prompt>})
Agent({subagent_type: "general-purpose", model: "sonnet", description: "Data flow trace",
  prompt: <data-flow prompt>})
Agent({subagent_type: "general-purpose", model: "sonnet", description: "Control flow trace",
  prompt: <control-flow prompt>})
Agent({subagent_type: "general-purpose", model: "sonnet", description: "Failure modes scan",
  prompt: <failure-modes prompt>})
```

Confirm the dispatched sub-agent actually has access to the `mcp__pyghidra-mcp__*` tools this
skill declares before relying on its returns -- this was not independently verified on this host
(see `SKILL.md`'s `## Limitations`).

## After dispatch

Unchanged: the orchestrator collects all returns, then runs the verification protocol
(`references/verification-protocol.md`). Do not begin rendering until verification completes for
all dispatched modes.

## Re-dispatch

Unchanged: if a sub-agent returns malformed output (missing citations, prose-only, wrong shape),
re-dispatch *that mode only* with a sharpened prompt. Limit to two attempts; escalate to the user
on a third garbage return.
