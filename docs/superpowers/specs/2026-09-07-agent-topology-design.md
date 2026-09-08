# Agent topology — design

**Status:** design, approved 2026-09-07. Branch `feat/agent-topology`, based on
`feat/skills-vendoring` (`3ffa8ac`), not on `main` — see AG7.

Companion to `docs/superpowers/specs/2026-09-06-skills-vendoring-design.md`. Where that
slice vendors *instructions* from upstream, this one authors *actors* and bounds what each
may touch.

---

## 1. Goal

Generate three specialist subagent definitions into `C:\re\agent\.claude\agents\`, each with
an explicit, data-derived tool grant, so that analysis, debugging and verification run in
separate contexts with separate reach.

### 1.1 Why now

`docs/BLUEPRINT.md` §5 records the orchestration patterns that are known to work — separate
static and dynamic agents, plus a cross-validation agent — and §3 records why the third one
matters: clearbluejar's result is that *an extra verification stage beats a better first
pass*, because precision, not recall, is the hard problem. `docs/DEPLOYMENT_PLAN.md` Phase 7
states the boundary in one line: **"If the verifier can write, it isn't a verifier."**

The MVP deferred all of it. The skills slice put subagents explicitly out of scope (§1.2).
This slice closes that gap for the three agents whose boundaries can be stated and checked.

### 1.2 Out of scope

- **The orchestrator agent, and the `Task` grant it would need** (AG2). Triage → deep-dive
  fan-out is therefore not delivered.
- **A verification oracle.** BLUEPRINT §9 Phase 4 wants the verifier to have emulation plus
  capa/PDB grounding; none is installed. See §12.
- **`settings.json` default-deny for the main session.** DEPLOYMENT_PLAN Phase 7 specifies
  it; `New-ClaudeSettingsObject` emits no `permissions` block at all. Recorded in §12 as a
  known divergence, not fixed here.
- **Hooks.** DEPLOYMENT_PLAN Phase 7's five hooks are what make the boundary mechanical
  rather than aspirational. Still deferred.
- **Agent-level audit trail (GAP C2).** Mitigated in prose only, per AG6.

### 1.3 Definition of done

1. `.\Install-REAgent.ps1` generates three agent files whose every granted tool is derived
   from `data/tool-catalog.json`, never hand-listed.
2. The gate (§8) fails closed on an unclassified tool, an absent tool, a stale
   classification, or a writer granted to the verifier.
3. `-VerifyOnly` runs the whole gate on a host where the generation phase has never run.
4. A second run regenerates byte-identical files and reports no change.
5. The manifest records each agent, its enable state, its server reach, and its tool count.

---

## 2. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| **AG1** | **Author the agent definitions here; do not vendor them.** | The boundaries are defined by *this host's* five-server tool surface. No upstream pack knows it. Authoring removes the supply chain, the tree hashes and the human review gate from this slice entirely — the security control is the generated grant itself, which §3 measured to be real. |
| **AG2** | **Three specialists; no orchestrator; no agent gets `Task`.** | An agent that can spawn agents is a reach amplifier: the verifier's read-only grant means less if something upstream of it can spawn a writer. Routing moves to `CLAUDE.md` prose driven by the main session. This also settles `SKILLS_SIGNOFF.md`'s open question on the `route` pack's `Task` grant in the same direction — narrow it. |
| **AG3** | **Tools are classified `read` / `write` / `destructive`; agents declare a maximum level.** | A single `readOnly` boolean leaves `delete_project_binary` granted to the static analyst. Three levels close that, and `destructive` is granted to nobody by default. |
| **AG4** | **Classification lives beside the captured tool list, never inside it.** | `-UpdateToolCatalog` refreshes `tools[]` from live servers. A classification stored in the same array would be silently erased by a refresh, or would block one. Separating them lets a refresh add a tool and lets the gate fail on it as unclassified. |
| **AG5** | **The permission fence is the agent's `tools:` frontmatter, and this was measured before the design relied on it.** | See §3. The immediately preceding commit on the base branch (`3ffa8ac`) corrected exactly this class of error for skills' `allowed-tools`. Repeating it for a component whose entire value is the fence would be worse. |
| **AG6** | **Every agent stamps its findings with its own name and the tool calls behind them.** | GAP C2 wants a correlation-ID'd record of what the agent did. Three agents multiply that gap — claims arrive from three contexts with nothing recording which produced which. Prose is not C2, but it stops C2 getting harder to retrofit. |
| **AG7** | **Base on `feat/skills-vendoring`, not `main`.** | `main` carries no `data/` directory, no `ReAgent.Skills.psm1` and no `## Skills` section in the template. This slice reads the tool catalog and mirrors the skills gate. It must merge after that branch. |

---

## 3. The measurement that grounds this

**Measured 2026-09-07 on Claude Code 2.1.263**, the same version as the skills measurement,
by A/B/C probe in a throwaway project outside the repo. Three agents identical but for their
frontmatter, one session configuration held constant (`--allowedTools "Task,Bash,Read"`).

| Arm | `tools:` declared | Observed tool set |
|---|---|---|
| A | `Read` | exactly `Read`. Bash absent from the set; no Bash call was made |
| B | *key omitted* | broad set including **every connected MCP server**; **Bash executed for real** |
| C | `Read, mcp__claude_ai_Google_Drive__search_files` | exactly those two; the seven sibling Drive tools absent |

**Conclusion: the `tools:` key constrains a subagent's tool set, per tool, MCP tools
included.** This is a different mechanism from a skill's `allowed-tools`, which `3ffa8ac`
measured to neither grant nor restrict.

**Recorded honestly, because the asymmetry matters:**

- Arms A and C are *absence* evidence, self-reported by the subagent. Arm B is the only
  positive execution. Absence cannot be proven by execution, so the A/B/C contrast under
  identical session configuration is the evidence — not any single agent's word for it.
- Arm B's subagent **fabricated two tool names** in its first report and retracted them when
  challenged. Subagent self-report is unreliable in detail. This is itself an argument for
  the static gate in §8: the repo checks the generated file, never asks the agent.
- **Omitting `tools:` is not neutral.** Arm B inherited Gmail, Google Calendar and Google
  Drive tools inside what was nominally a reverse-engineering session. Every agent this slice
  generates therefore declares `tools:` explicitly, including agents that want a wide grant.

A guard test asserts no document in this repo reasserts that a *skill's* `allowed-tools`
restricts anything; this spec's claim is about an agent's `tools:`, which is a distinct key.

---

## 4. Topology and grants

| Agent | Level | Servers | Built-ins |
|---|---|---|---|
| `static-analyst` | `write` | pyghidra-mcp, binaryninja | `Read`, `Glob`, `Grep` |
| `dynamic-analyst` | `write` | x64dbg-x64, x64dbg-x32, mcp-windbg | `Read`, `Glob`, `Grep` |
| `verifier` | `read` | pyghidra-mcp, mcp-windbg | `Read`, `Glob`, `Grep` |

No agent gets `Bash`, `Write`, `Edit`, `NotebookEdit` or `Task`. BLUEPRINT §7.1 mitigation 1
is explicit: no host-code-execution tools while the model is reading untrusted content, and
all three read decompiler and debugger output.

**A consequence to accept deliberately:** the vendored `ghidra` skill declares blanket `Bash`
for `scripts/msvc_demangle`. Inside `static-analyst` there is no `Bash`, so that script cannot
run. Since `3ffa8ac` established that a skill's declaration is intent rather than grant, the
skill was never going to obtain `Bash` by declaring it; what changes here is that the agent
context genuinely lacks it. The skill must degrade gracefully or be invoked from the main
session. Recorded in §12.

### 4.1 The verifier's lead contract

The verifier's template opens with the `ai_` exclusion rule, not with its tool list:

> When harvesting evidence, EXCLUDE every symbol whose name begins with `ai_`. Those names
> were proposed by a model, possibly by an earlier stage of this same investigation. A read
> that confirms them is self-corroboration, not confirmation. If the only support for a claim
> is an `ai_*` name, the claim is unverified — say so.

This is not decoration. `docs/GAP_ANALYSIS.md`'s GeReV entry names the failure precisely:
*"you can corroborate your own guesses — apply an AI inference, re-read, and the confirming
read looks independent when it isn't."* Without this rule, adding a verifier makes output look
better-verified while verifying nothing, which is worse than having no verifier. The `ai_`
prefix convention is already established in `templates/CLAUDE.md.template`; here it is
promoted from a general contract to the verifier's first instruction.

### 4.2 What the dynamic analyst cannot do

DEPLOYMENT_PLAN §D1 names TTD-record-then-query as the preferred dynamic style. It is
unavailable: the in-box `dbgeng.dll` rejects `.run` replay with `0x80070057` and lacks
`!analyze`, which is why `windbg-ttd` already ships disabled. The template says so, so the
agent reports the limitation rather than discovering it mid-case.

---

## 5. Tool classification

`data/tool-catalog.json` gains a `classification` object per server, a sibling of the
captured `tools[]` (AG4):

```jsonc
"pyghidra-mcp": {
  "pin": "0.2.5",
  "toolCount": 20,
  "tools": [ /* captured by -UpdateToolCatalog; unchanged by this slice */ ],
  "classification": {
    "classifiedBy": "",
    "classifiedAt": "",
    "classifiedTools": [ /* every name, exactly as classified */ ],
    "write":       [ "rename_function", "rename_variable", "set_comment",
                     "set_function_prototype", "set_variable_type", "save" ],
    "destructive": [ "delete_project_binary" ]
  }
}
```

Anything in `classifiedTools` and in neither list is `read`. A tool's level is the highest
list it appears in. An agent at level `write` receives `read` + `write`; at `read`, only
`read`; `destructive` is granted to no agent by any level.

**Completeness is what makes it fail closed.** Check A4 compares `classifiedTools` against
`tools` as sets. A refresh that adds a tool leaves the sets unequal and the gate stops. A
tool that is merely missing from `write` would otherwise be silently treated as readable and
handed to the verifier — the exact failure the boundary exists to prevent.

`-UpdateToolCatalog` writes `tools`, `toolCount` and `pin` only. It never touches
`classification`, and never removes one for an unreachable server.

---

## 6. Config schema

`re-agent.config.json` gains an optional top-level `agents[]`. Optional matters: a config
without the key must still load, which is the StrictMode defect the skills slice already hit
in `Get-RecordedSkillResult`.

```jsonc
"agents": [
  { "name": "verifier",
    "enabled": true,
    "level": "read",
    "targetServers": ["pyghidra-mcp", "mcp-windbg"],
    "builtinTools": ["Read", "Glob", "Grep"],
    "model": "inherit",
    "disabledReason": "" }
]
```

Schema rules, enforced at load:

1. `name` matches `^[a-z][a-z0-9-]{2,31}$` and is unique. It is also the file basename and
   the frontmatter `name:` — check A0 exists because Claude Code will not load a file where
   those disagree.
2. `level` is one of `read`, `write`, `destructive`. `destructive` is rejected outright: no
   agent may declare it. The value exists so the classification can name the class, not so an
   agent can request it.
3. `targetServers` entries must name servers present in `mcpServers[]`.
4. `builtinTools` may not contain `Bash`, `Write`, `Edit`, `NotebookEdit` or `Task`.
5. `enabled: false` requires a non-empty `disabledReason`, mirroring the per-skill rule.
6. `model` is `inherit` for now. The field exists because BLUEPRINT §6 routes bulk annotation
   to a local tier and hard reasoning to a frontier model, and GAP C4 makes that routing a
   cost control. `static-analyst` is the first candidate. Nothing reads the field this slice.

---

## 7. Generation and disk layout

Templates at `templates/agents/<name>.md.template`, substituted with `{{TOOLS}}`,
`{{SERVERS}}` and `{{LIMITATIONS}}` — simple token replacement, per DEPLOYMENT_PLAN Part 4's
instruction to resist a templating engine.

Output: `C:\re\agent\.claude\agents\<name>.md`.

Generation folds into **phase 4 (`AgentConfig`)** rather than taking a new phase id. That
phase already owns exactly this job — `.mcp.json`, `settings.json` and `CLAUDE.md` generated
from data — and folding in avoids renumbering `Select-Phase` and `-VerifyOnly`. The gate runs
in phase 6 beside the skill gate.

Removal of orphaned agent files is **scoped to names this config knows**. The shared
`.claude/agents/` directory may hold files this installer did not write; deleting by "not in
my wanted list" against a shared root is the defect the skills slice shipped and had to fix.

Tool list ordering is deterministic — built-ins in declared order, then MCP tools sorted by
name — so a re-run reproduces the file byte for byte.

---

## 8. The gate

New module `src/ReAgent.Agents.psm1`. Checks are `A`-prefixed so they never read as skills'
`G0`–`G4`. All five read only the repo and the generated files, so all five run on every
verification, including `-VerifyOnly` on a host where phase 4 has never run.

| id | Fails when |
|---|---|
| **A0** | frontmatter `name:` ≠ file basename ≠ config `name` — Claude Code will not load it |
| **A1** | a `targetServers` entry has no catalog entry, so A2–A4 cannot judge it |
| **A2** | a granted `mcp__<server>__<tool>` is absent from the catalog's `tools[]` |
| **A3** | an agent is granted a tool above its declared level, or any of the five forbidden built-ins |
| **A4** | `classifiedTools` ≠ `tools` for a granted server — the classification is stale |

A3 is the one that carries DEPLOYMENT_PLAN's line. For the verifier it reduces to: no tool in
`write` or `destructive`, and no built-in writer. If A3 passes and the file still grants a
writer, the generator is wrong, not the gate.

---

## 9. The routing contract

`templates/CLAUDE.md.template` gains an `## Agents` section, generated alongside the existing
`## Skills` section:

- which agent to reach for, and that the main session routes — no agent spawns another;
- that the verifier runs **last and independently**, and that its `ai_*` exclusion is the
  reason its confirmation counts for anything;
- that an agent reporting a missing tool has hit its grant, not a broken server, and the
  remedy is a config change plus a re-run — never a workaround;
- that findings carry the name of the agent that produced them (AG6).

The existing precedence line stands: where a skill or an agent conflicts with `CLAUDE.md`,
`CLAUDE.md` wins and the conflict is reported as a finding.

---

## 10. Manifest, phases, idempotency

Manifest gains an `agents[]` block: name, enabled, disabledReason, level, servers reached,
granted tool count, and the gate result. `Get-RecordedAgentResult` replays it for
`-VerifyOnly`, guarded against a config with no `agents` key.

Idempotency: files are written through `Write-FileIfChanged`. A steady-state run reports no
change and touches no timestamp — the lesson from the launcher-rewrite regression, where
unconditional writes made a staleness check fire on every run.

---

## 11. Testing

Pester, house conventions: pure decision functions unit-tested with the host mocked, side
effects thin and behind existing seams.

Negative tests that must actually fail, mirroring the skills spec's §11.3 discipline:

1. An agent granted a tool absent from the catalog → **A2**.
2. The verifier granted a tool listed in `write` → **A3**.
3. A catalog refresh that adds a tool without classifying it → **A4**.
4. A frontmatter `name:` that disagrees with its filename → **A0**.
5. An agent declaring `Bash` in `builtinTools` → rejected at config load.

Each is asserted to fail *before* the fix that makes it pass, per the repo's TDD discipline.

---

## 12. Known gaps and deliberate divergences

| # | Gap | Disposition |
|---|---|---|
| 1 | **The verifier has no oracle.** BLUEPRINT §9 Phase 4 wants emulation plus capa/PDB grounding; GAP C6 calls the oracle the deferred core value. | Ships the verifier's shell. The schema makes the fix additive: `reverify`, `re-capa` or `angr.mcp` become a server entry plus a `targetServers` line, not a rewrite. |
| 2 | **Triage → deep-dive fan-out is not delivered**, because no agent gets `Task` (AG2). | Two of BLUEPRINT §5's three patterns ship: the static/dynamic split and the cross-validation stage. |
| 3 | **Nothing makes the verifier run.** Without an orchestrator the verification stage is prose, not enforcement. | Stated in `CLAUDE.md`. The honest framing: this slice delivers a verifier you can invoke, not a stage that always runs. |
| 4 | **`settings.json` has no `permissions` block**, so the main session is unbounded while the three subagents are bounded. DEPLOYMENT_PLAN Phase 7 specifies default-deny then allowlist. | Pre-existing, not introduced here. Arm B of §3 shows what an unbounded context reaches. Next slice. |
| 5 | **DEPLOYMENT_PLAN Tier 3 lists the boundary test as recurring**; §3 ran it once. | Deliberate. The static gate runs every time; re-measure when Claude Code's minor version moves. |
| 6 | **The `ghidra` skill's `Bash` dependency does not work inside `static-analyst`.** | §4. Degrade the skill or invoke it from the main session. |
| 7 | **x64dbg's 80 tools and Binary Ninja's 75 are not in the catalog**, so `dynamic-analyst` and the Binary Ninja half of `static-analyst` cannot be generated until an attended capture runs. | A1 fails closed. If the capture cannot run, `dynamic-analyst` ships `enabled: false` with a recorded reason; the verifier needs only the two unattended servers and lands either way. |

---

## 13. References

- `docs/BLUEPRINT.md` §3 (precision is the hard problem), §5 (orchestration patterns,
  contract lines), §7.1 (no execution while reading untrusted content), §8 (the agent
  directory), §9 Phase 4 (verifier gets an oracle)
- `docs/DEPLOYMENT_PLAN.md` §D1 (TTD preferred), Part 4 (templating), Phase 7 (default-deny,
  hooks, "if the verifier can write, it isn't a verifier"), Part 6 Tier 3 (boundary test)
- `docs/GAP_ANALYSIS.md` C2 (audit trail), C4 (cost), C6 (oracle), GeReV entry
  (self-corroboration)
- `docs/superpowers/specs/2026-09-06-skills-vendoring-design.md` §4.3 (rules as data), §8
  (the gate), §10 (manifest, phases, idempotency), §11.3 (negative tests)
- Commit `3ffa8ac` — `allowed-tools` neither grants nor restricts; the precedent AG5 follows
