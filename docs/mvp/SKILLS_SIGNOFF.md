# Skill pack sign-off — the human review gate

Eight packs are vendored and adapted. **All eight were signed off on 2026-09-08** —
`reviewedBy: david` under `skills[<ns>].review` in `re-agent.config.json` — and all eight
install. Before that sign-off `Install-SkillPack` refused each with *"human review gate: no
sign-off recorded"*, which was deliberate: an agent must not record an attestation a person
never made.

This file is the checklist that attestation was made against, and the record of the open
decisions it accepted. Re-work it whenever a pack's pin moves. It is not a substitute for
reading the files — spec §4.5: *the real cost of this slice is the human review, not the PowerShell.
The scanner is the backstop that catches what a tired reader misses.*

---

## For every pack

1. **Read every `SKILL.md` in full**, plus its reference files. These are instructions the
   agent will follow.
2. **Confirm the upstream is the one you meant** — not a near-identical fork. Check
   `source.repo` and `source.commit` against the real repository. `dariushoule/x64dbg-skills`
   has at least four near-identical forks; assume every popular pack does.
3. **Check `allowed-tools` against what the skill actually does.** Measured on Claude Code
   2.1.263, this key does **not** restrict a skill at runtime: a project skill declaring only
   `Read` still drove `Bash`, and one declaring `Bash` was still denied it when the session
   denied it. It neither grants nor restricts, so narrowing a list buys you no containment.
   Read it as a statement of intent - `Bash`, `Write`, `Edit` or `Task` far broader than the
   body needs means the body deserves a harder read - and note that a tool the body drives but
   does not declare still makes G1 pass vacuously. The runtime fence is session permissions
   plus your own read of the body.
4. **Check every disabled skill's `disabledReason`** still states a true reason you agree with.
5. Then record, under `skills[<ns>].review` in `re-agent.config.json`:
   `reviewedBy`, `reviewedAt`, and `notes` saying what you actually read.
   `reviewedCommit` is already set and must keep matching `source.commit`.

Verify after: `Invoke-Pester -Path tests/` then `.\Install-REAgent.ps1 -VerifyOnly`.

---

## What the gate cannot check

The review rounds that added `reva`, `tob` and `arch` to this file found five defects, and the
automated gate caught none of them. Every one was a true-or-false statement about this host or
about upstream: a `disabledReason` denying a debugger this install actually ships (it ships
three, all enabled); a sentence telling the agent this install exposes only the ten or sixteen
tools one skill happens to declare in `allowed-tools`, when the server behind it exposes twenty;
a `## Limitations` bullet claiming a triage step lost its upstream bookmark tracking, when
upstream's own triage skill never used bookmarks either; a third-party API's documented default
value for an edge-confidence field stated backwards, inverting the one rule the pack exists to
enforce; and, introduced by a later fix round itself, thirteen sibling skills still described in
`## Limitations` as "vendored but disabled" after they had been deleted from the tree entirely.
G0-G4 check names, structure, and tool-name membership. The scanner checks for hostile patterns.
**Neither checks whether a sentence is true.** Finding these took reading upstream's source,
comparing GitHub blob hashes, and reading this repo's own config line by line — that is what
spec §4.5 means by the real cost being the human review, and it is the specific failure mode to
watch for while reading everything below.

---

## Open decisions carried forward, per pack

These came out of the vendoring tasks and the whole-branch review. Each is a judgement call
that belongs to the operator, not to the agent that vendored the pack.

### `windbg` — svnscha/mcp-windbg

- **Enable live and kernel debugging, or leave them off?** `windbg-live-debugging` and
  `windbg-kernel-debug` ship disabled. Their original `disabledReason` claimed the tools did
  not exist; that was false — this host's mcp-windbg 1.2.1 advertises all ten, including
  `open_cdb_remote`, `open_kd_session`, `run_kd_command`, `send_ctrl_break` and
  `wait_for_break`. They are off because enabling live-process and kernel debugging by default
  is a risk-scope decision nobody has made, not because the capability is missing. Both now
  declare the tools they drive, so enabling them is a one-flag change once you decide.
- Confirm the two `dbgeng.dll` gotchas in `windbg-crash-analysis` still hold on this host
  (in-box `dbgeng.dll` rejects `.run` TTD replay with `0x80070057`, and lacks `!analyze`).

### `ghidra` — GeReV/ghidra-iterative-re

- **`allowed-tools` declares blanket `Bash`** for the whole skill, needed by
  `scripts/msvc_demangle`. Because the key does not fence anything at runtime, narrowing it
  changes nothing: the real question is whether you accept a skill whose body reaches for a
  shell at all, and whether pyghidra's Python library is shell-reachable in a way that steps
  around pyghidra-mcp's own tool boundary. Use session permissions if you want a real fence.
- Upstream diverged much further than the spec anticipated: one 459-line skill plus roughly
  9,300 lines of PyGhidra-*scripting* reference material that this tool surface cannot
  execute. The adaptation covers `SKILL.md`; **rewriting the reference corpus was explicitly
  deferred to this review**, not silently dropped. Decide whether to trim it, annotate it, or
  accept it as background reading.
- The `ai_` prefix convention and its `## Limitations` section are load-bearing (spec §5) and
  locked down by a test. Read them and confirm you agree with the trust model.

### `re` — hackersifu/reverse-engineering-skills

- Declares no MCP tools; both skills work from evidence the analyst already has. Confirm that
  matches what you want — they will not drive a server themselves.

### `route` — ljagiello/ctf-skills (`ctf-reverse`)

- **A source substitution.** The pack the spec named (`majiayu000/claude-skill-registry` →
  `reverse-engineering`) turned out to be a stale aggregator-mirror slug pointing at unrelated
  content — a Japanese architecture-documentation skill, confirmed via the registry's own
  `metadata.json`. The registry's scrape provenance led to the real author,
  `ljagiello/ctf-skills`' `ctf-reverse` skill, which was vendored instead. Every link in that
  chain was independently verified against live GitHub (3,191 stars, actively maintained,
  pinned commit was HEAD at vendor time). **Confirmed and accepted at sign-off (2026-09-08).**
- **`allowed-tools` originally declared `Write`, `Edit` and `Task`** with no line in the body
  ever calling any of them — grepped in full at sign-off. Trimmed to `Bash`, `Read`, `Glob`,
  `Grep` (2026-09-08) to match what the routing body actually does; the key doesn't fence
  anything at runtime either way, so this changed the declaration's honesty, not its behavior.

### `dotnet` — fenzel999/dotnet-artisan (`dotnet-debugging`)

- Six `toolRenames` map the upstream `*_windbg_*` names onto this host's `*_cdb_*` surface,
  and G2 now checks all fifteen reference files, not just `SKILL.md`. Spot-check a couple of
  the SOS command packs against a real dump anyway.
- The skill's prose deliberately *discusses* the live-attach and kernel tools it does not use.
  That is correct and should stay; it is also why a blanket "declares what it names" sweep is
  the wrong shape of test.

### `reva` — cyberkaida/reverse-engineering-assistant

- Ships **2 of 6** skills enabled: `reva-binary-triage` and `reva-deep-analysis`. Four ship
  disabled: `reva-ctf-rev`, `reva-ctf-crypto`, `reva-ctf-pwn`, `reva-pyghidra-scripting`.
- **The four disabled skills are held by the `enabled` boolean and nothing else.**
  `Install-SkillPack` and `Test-SkillPackGate` both iterate enabled skills only, so flipping one
  to `true` ships an un-adapted upstream body past **all four gate checks**: G0 passes
  (directories were renamed), CATALOG passes, G1 passes vacuously (those skills have no
  `allowed-tools` block at all), G2 passes vacuously (`toolRenames` is empty).
  `reva-pyghidra-scripting`'s description still names five ReVa scripting tools
  (`run-script`, `list-scripts`, `read-script`, `write-script`, `edit-script`) and would go live
  instructing the agent to call tools that do not exist here. Disabled is safe; enabling is a
  cliff with no guardrail. **This is the single most important item for the reader to
  understand.**
- **5,696 measured lines** of un-adapted companion content ship across the four disabled skill
  directories (12 files) in the vendored tree that no installer run ever scans — the red-flag
  scanner runs per *enabled* skill directory only. It was scanned once by hand and was clean;
  that is a one-time result, not a standing control.
- Upstream ReVa expects capabilities `pyghidra-mcp` does not have (no bookmark tool, no function
  enumeration or count, no structure definition, no memory-block listing, no function-similarity
  search). These are written into each skill's `## Limitations` rather than papered over — the
  adapted skills are genuinely thinner than upstream's.

### `tob` — trailofbits/skills, the `trailmark` skill

- Ships **one** skill, `tob-trailmark`. The pack was originally vendored with all 14 of
  upstream's `trailmark`-plugin skills and was narrowed on review to just this one; the other 13
  were never adapted and are not present in the repo or the config in any form. They covered
  source-tree workflows (mutation testing, SARIF/CodeQL/Semgrep integration, git-diff review
  gates, formal-verification spec generation) that this host cannot run against a stripped
  binary.
- Its `confidence` discipline is the reason this pack was chosen — *"reachability is not taint;
  verify data flow by hand before claiming it"* survives verbatim from upstream. Review found
  and fixed a defect that **inverted** it: the skill stated that omitting Trailmark's
  `confidence` field defaults an edge to `"inferred"` when the importer actually defaults it to
  `"certain"`, which would have marked every Ghidra-inferred call edge as certain. Worth
  re-reading that section specifically, since it is the pack's whole value.
- Its `pyghidra-mcp`-output-to-Trailmark-JSON field mapping is **this adaptation's own
  construction**. The target schema was verified against Trailmark's real source, but the
  mapping was never smoke-tested against a live `pyghidra-mcp` response. The skill says so
  plainly and tells the reader to treat a mismatch as a reason to change the mapping, not the
  schema — **accepted at sign-off (2026-09-08)**.
- **This is the only pack on the branch that instructs a mid-session tool install.** `SKILL.md`
  says `uv tool install trailmark` is `MANDATORY` if the CLI is missing — unpinned, resolved from
  PyPI at run time, with no entry in `mcpServers[]` or `data/tool-catalog.json`. Every sibling
  pack (`re-unpacker`, `windbg-doctor`, `arch`, `route-triage`) explicitly forbids installing
  tools mid-session; this skill's own text admits it sits outside the reviewed MCP surface rather
  than hiding it. **Accepted at sign-off (2026-09-08)** — Trail of Bits is a reputable vendor and
  `uv tool install` is a sandboxed-venv install, not a raw binary fetch.

### `arch` — NickCrew/Claude-Cortex, `architectural-analysis`

- Ships one skill, but it is large: **4,743 measured lines across 27 files**. Only 5 files were
  fully rewritten; the other 10 reference files carry an "on this host" banner note rather than
  a full rewrite, and 4 of the 8 analysis modes are marked NOT SUPPORTED (information
  architecture, data model, UI surfaces, interaction patterns — none exist below source level in
  a stripped binary). Review confirmed `SKILL.md` never routes the agent into a NOT-SUPPORTED
  file.
- **Declares `Agent`, `Bash` and `Write`.** Each is genuinely used — `Agent` for its phase-3
  subagent dispatch, `Bash` for bundled scripts, `Write` for reports. Flagged rather than
  silently narrowed, because narrowing the list fences nothing. Note that spec §1.2 puts
  subagent definitions out of scope for this slice, so `Agent` deserves a deliberate decision.
- **Its rendering phases do not work on this host.** `render.sh` needs `mmdc` (mermaid-cli) and
  `compile-html.sh` needs `pandoc`; neither is installed. The skill documents this and the
  scripts fail loudly rather than silently, and `.mmd`/`.md` artifacts are still produced.
  Installing those two packages is optional and would enable diagram rendering — an install
  decision, not a content one.

---

## After sign-off

The end-to-end proof was left for you, because a real (non-`-VerifyOnly`) run mutates this
machine:

```powershell
.\Install-REAgent.ps1
.\Install-REAgent.ps1     # every pack 'skipped'; no skill file timestamp changes
```

Then in `C:\re\agent`, run `claude`, confirm `/` lists the namespaced skills, and invoke
`windbg-crash-analysis` against the phase 3 test dump.

The four negative tests in spec §11.3 are worth running by hand once, each reverted after:
a tool the catalog lacks (**G1**), an upstream name left in the prose (**G2**), a
permission-skipping flag in a vendored file (**scan blocks, installed copy removed**), and a
server pin bumped without refreshing the catalog (**G4**).

Two controls here are weaker than they look; see `docs/mvp/HANDOFF.md` for the full detail
before you rely on either: `treeSha256`'s covered scope varies by pack layout (*"`treeSha256`'s
covered scope varies by pack layout"*), and the `reviewedBy`/`reviewedAt` schema rule is not
enforced (*"`reviewedBy`/`reviewedAt` schema rule — not implemented, deliberately"*).
