# Skill pack sign-off — the human review gate

Five packs are vendored and adapted. **None is signed off, so none installs.**
`Install-SkillPack` refuses each with *"human review gate: no sign-off recorded"* and
`Get-ManualStep` repeats it in the manifest. That state is deliberate: an agent must not
record an attestation a person never made.

This file is the checklist for making that attestation. It is not a substitute for reading
the files — spec §4.5: *the real cost of this slice is the human review, not the PowerShell.
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

- **A source substitution needs your explicit confirmation.** The pack the spec named
  (`majiayu000/claude-skill-registry` → `reverse-engineering`) turned out to be a stale
  aggregator-mirror slug pointing at unrelated content — a Japanese architecture-documentation
  skill, confirmed via the registry's own `metadata.json`. The registry's scrape provenance
  led to the real author, `ljagiello/ctf-skills`' `ctf-reverse` skill, which was vendored
  instead. Every link in that chain was independently verified against live GitHub
  (3,191 stars, actively maintained, pinned commit was HEAD at vendor time). **It was not
  auto-approved.** Confirm the substitution before signing off, or reject it and drop the pack.
- **`allowed-tools` declares `Write`, `Edit` and `Task`** on a skill whose own description says
  it "decides which server or skill to reach for, then hands off". `Task` spawns subagents,
  which spec §1.2 puts out of scope for this slice. Narrowing the list does not fence it, so
  decide on the body: accept that reach deliberately, or cut the instructions that use it.

### `dotnet` — fenzel999/dotnet-artisan (`dotnet-debugging`)

- Six `toolRenames` map the upstream `*_windbg_*` names onto this host's `*_cdb_*` surface,
  and G2 now checks all fifteen reference files, not just `SKILL.md`. Spot-check a couple of
  the SOS command packs against a real dump anyway.
- The skill's prose deliberately *discusses* the live-attach and kernel tools it does not use.
  That is correct and should stay; it is also why a blanket "declares what it names" sweep is
  the wrong shape of test.

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
