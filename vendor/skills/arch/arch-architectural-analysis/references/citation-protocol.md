# Citation Protocol (binary-graph adaptation)

## On this host

Retargeted in full from upstream's `path:line` contract. This is the load-bearing rewrite this
pack exists for: **every node and edge that upstream grounds in a source line is grounded here in
a function name plus address**, verified against `pyghidra-mcp`, not a file on disk. Where
upstream says "grep the codebase," this file says "query `pyghidra-mcp`."

The load-bearing rule of this skill, unchanged: a diagram is a set of falsifiable claims; a
citation is what makes a claim falsifiable. Without strict citation, the skill produces
confident-looking architectural fiction.

## Core rules

1. **Every node carries a callout ID and a `<function-or-symbol>@<address>` citation.**
   - Format: `symbol@0xADDRESS` (e.g. `ai_decrypt_payload@0x00401234`), hex address as reported by
     `pyghidra-mcp` (`decompile_function`, `disassemble`, `list_xrefs`, or
     `search_symbols_by_name`).
   - The address cited is where the symbol is *defined* -- a function's entry address, or the
     address of a specific instruction/decompiled statement inside it when the claim is about
     that statement specifically. Not a caller's address.
   - **Open question, unverified on this host:** whether `decompile_function`'s returned pseudo-C
     carries a reliable per-line address mapping is not confirmed here. If it does not, cite
     decompiled-line claims at the function's entry address and get instruction-level addresses
     from `disassemble` instead. Say which you did; do not assume line-level addressing works
     until you have checked a live response.

2. **Every edge carries a citation.**
   - The address where the relationship is established: a call instruction's address (from
     `list_xrefs` or `disassemble`), not an import-statement line -- there are no imports in the
     upstream source sense, only calls, memory references, and (via `list_imports`) linked
     external symbols.
   - If the edge spans an indirect or computed call target, cite the address of the *call site*,
     and mark the edge's confidence accordingly (see `## What is NOT a citation` below and the
     `tob` pack's `confidence` discipline, which applies the same reasoning to the same kind of
     Ghidra-inferred edge).

3. **Absence claims check the binary first.**
   - Findings of the shape "no X handler", "missing Y", "doesn't validate Z" must check
     `search_strings`, `search_symbols_by_name`, `list_imports`, or `list_exports` for the
     asserted-missing symbol *before* the finding is recorded -- there is no source tree to `grep`.
   - Sub-agents over-fire on absence claims because they reason from a short window of
     decompiled/disassembled output. The orchestrator discards any absence claim where the symbol
     turns up in one of these tool results.

4. **Quoted code is exact.**
   - Evidence strings in findings are verbatim copies of the cited decompiled-C line
     (`decompile_function`) or disassembly instruction (`disassemble`), exactly as the tool
     returned it. Paraphrase counts as fabrication; reject and re-cite.

## Synthesized concepts

Some architectural truths don't live in a single function. Examples on this host:

- "The decryption pipeline" -- embodied across several functions that each transform a buffer,
  none of which alone "is" the pipeline.
- "The C2 protocol handshake" -- implicit in a sequence of network calls and a parsing function,
  not stated anywhere as a named unit.
- "The anti-debugging check chain" -- emerges from several unrelated-looking checks whose common
  purpose is only visible once you've traced all of them.

These are real and worth diagramming. They are also the primary vector for fabrication. The
escape hatch, unchanged from upstream:

### Synthesized-node requirements

- Marked in mermaid with `classDef synthesized stroke-dasharray:5,stroke:#888` (see
  `mermaid-conventions.md`).
- Listed in a dedicated **Synthesized concepts** section of the report with a written
  justification.
- Justification names the *contributing functions* (cited individually, `symbol@address`) and
  explains why no single address owns the concept.
- Cap: **<=20% of nodes per mode** may be synthesized. Upstream's raised 35% cap for interaction
  patterns does not apply here -- that mode is NOT SUPPORTED on this host (see `SKILL.md`'s mode
  table).
- If a mode exceeds its cap, either:
  - Promote synthesized nodes to cited nodes by citing the most-canonical contributing function,
    or
  - Drop the weakest synthesized nodes until under the cap, or
  - Surface the cap breach to the user before proceeding (signals the binary's structure is
    unusually diffuse for this concept and may need a different framing).

Edges into or out of a synthesized node still need citations on the *cited* end. A
synthesized->cited edge cites the address in the cited function where the relationship surfaces.

## Citation format inside reports

In the markdown report, every callout entry resolves once in the **Callouts** table:

```markdown
| ID | Label | Citation | Confidence |
|----|-------|----------|------------|
| X-1 | ai_send_beacon (imports WinHttpOpen) | ai_send_beacon@0x00401810 | high |
| X-2 | C2 host string | search_strings hit @0x00405c20 | high |
| X-3 | "The C2 handshake" | -- | synthesized |
```

In narrative prose, refer to a callout by ID alone (`[X-1]`), not by re-citing the address. The
callout table is the source of truth.

## What is NOT a citation

- An address with no symbol/function context (`0x00401234` alone, with no function it belongs to)
  -- too vague, fails verification.
- An address range (`0x00401200-0x00401300`) -- pick the canonical address; ranges hide
  imprecision, same as upstream's line-range rule.
- A tool call as a stand-in (`search_symbols_by_name pattern="decrypt"`) -- that's how to find the
  citation, not the citation itself.
- A symbol name without an address (`ai_decrypt_payload`, no address) -- the verification protocol
  cannot resolve names without an address hint (`search_symbols_by_name` can return multiple
  matches; the address disambiguates).
- **An edge marked `certain` for an indirect or computed call target.** Ghidra's own call-target
  resolution is not infallible through function pointers, vtables, or PLT/import stubs -- mark
  these `inferred` or lower, per the same discipline the `tob` pack's binary-graph confidence
  field uses for the same underlying data source.

## Verification log section

Every per-mode `report.md` includes a **Verification log** section listing:

- Findings discarded as fabricated (with the bad citation and why it failed).
- Absence claims rejected (with the `search_strings`/`search_symbols_by_name`/`list_imports`/
  `list_exports` evidence the asserted-missing symbol exists).
- Synthesized cap pressure (if synthesized share approached the cap).
- Citations the orchestrator could not verify and why (e.g., the address moved because the
  function was re-analyzed or renamed mid-session).

A clean verification log is suspicious. A real run nearly always discards something. An empty log
signals the orchestrator skipped the pass.
