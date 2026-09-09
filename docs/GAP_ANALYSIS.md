# Gap Analysis — Agentic RE Blueprint & Deployment Plan

> **Status, 2026-09-08:** eight of the packs surveyed below were vendored, adapted and gated
> under `vendor/skills/` on branch `feat/skills-vendoring` (windbg, ghidra, re, route, reva,
> dotnet, tob, arch — see `docs/mvp/SKILLS_SIGNOFF.md` for what shipped and what's still open
> per pack). x64dbg was deferred by explicit decision; Binary Ninja's server exists but has no
> skill pack yet. Everything else named below (SpecterOps, wshobson, frida-skills,
> symbolic-execution-tools, `binary-re`, `symbol-recovery`, and the 13 dropped `tob` siblings)
> remains untouched — tracked as backlog in `docs/mvp/HANDOFF.md` under "Skill packs surveyed
> but not vendored." This file is otherwise the original, unedited survey.

Review of `BLUEPRINT.md` and `DEPLOYMENT_PLAN.md`, cross-checked against current (2026) MCP-security, agentic-malware-analysis, and Windows vuln-research practice. Findings are split into **Critical** (will block correctness, safety, or usability if unaddressed) and **Nice-to-have** (real value, not on the critical path).

Both documents are unusually complete. The trust boundary, prompt-injection-from-binary threat, supply-chain vetting, headless/aarch64 mapping, verification-stage-over-better-first-pass insight, and persistent case state are all already handled well. The gaps below are the things a careful second pass surfaces, not holes in the core thesis.

> **Sources that drove this pass:** MCP anti-patterns / hardening surveys (Endor Labs 2,614 servers: 82% path-traversal, 67% code-injection; AgentSeal 1,808: 66% with findings), Corelight's Black Hat NOC agentic-SOC write-up (kill switch, audit, cost), G Data's "LLMs in malware analysis" practitioner report (verdict unreliability, verification-token blowup, script-feedback-loop oracle, two-VM layout), Blazytko's pipeline, and WinAFL/DynamoRIO docs.

---

## Context change: this deploys onto an EXISTING FLARE-VM

You noted you'll install on top of a FLARE-VM that already has most tools. This invalidates a load-bearing assumption in `DEPLOYMENT_PLAN.md` (§D2, Phase 3, Part 10): *"produce a template from clean, install FLARE-VM yourself, seal, snapshot."* The consequences are large enough that I've promoted the reconciliation work to the top of the Critical list rather than treating it as an edit note.

The short version: **a pre-existing FLARE-VM is not a clean baseline.** It may carry prior-case contamination, live samples, saved credentials, tool drift, mismatched Defender/long-path/registry state, and an unknown install history. Turning it into a golden template without a reconciliation + hygiene pass means you snapshot someone's used workstation and call it clean.

---

## CRITICAL

### C1. No "adopt an existing dirty VM" path — the whole plan assumes greenfield
**Where:** `DEPLOYMENT_PLAN.md` D2, Phase 0–3, Part 10 (M2–M3).
**Gap:** Phase 3 is written as *install FLARE-VM*. Your box already has it. You need the inverse: **inventory → reconcile → decontaminate → verify**, not install.

What's missing and should be added before this VM becomes a template:
- **Provenance/hygiene sweep:** confirm no live samples outside a locked vault, no prior-case artifacts in `%TEMP%`/Downloads/Recent, no saved Anthropic/OpenAI/tailnet creds, no leftover Boxstarter `DefaultPassword`, clean PowerShell history. (Phase 9's seal already lists most of these — run that sweep *first*, on intake, not just at seal.)
- **State reconciliation instead of install:** Phase 3's `Test-FlareVM` sentinel check becomes the primary path; Phase 1's registry/Defender/long-path settings must be **read-and-reconcile** (the box may already differ), not blind-set.
- **Drift capture:** snapshot the existing tool inventory + versions into the manifest as the *actual* baseline, since you no longer control what FLARE-VM installed or when. You lose the reproducible-from-`config.xml` property — record what's really there instead.
- **Idempotency now matters more, not less:** every `Invoke-*` must tolerate "already present, possibly a different version." The plan's idempotency table (Part 5) is correct but was designed for *your* installs; it needs to handle installs you didn't do.
- **Decide the template question explicitly:** is this used VM *becoming* the golden template, or is it a one-off? If it's the template, a decontamination + fresh-snapshot gate is mandatory. Community consensus (r/cybersecurity, FLARE-VM maintainers) is explicit that a hand-built, reused FLARE-VM should be snapshotted clean before trusting it.

**Action:** add a Phase 0.5 "Adopt & reconcile existing environment" and rewrite Phase 3 as verify-and-fill-gaps. Treat the current box as untrusted until the hygiene sweep passes.

### C2. No agent-action audit trail / chain of custody
**Where:** Blueprint §7 hooks, DEPLOYMENT §7-hooks, Phase 9e manifest.
**Gap:** You have a `post-output-redact` hook and Start-Transcript per phase, but **nothing records what the agent itself did per case** — which tool it called, with what params, what it concluded, in a structured, correlation-ID'd, tamper-evident log that survives the Profile-B clone being destroyed. Every current MCP-hardening source treats this as non-optional; for malware work it's also your evidence record ("where did this IOC come from?"). A Profile-B clone is destroyed after each case — if the reasoning trail dies with it, you cannot defend a verdict or reproduce a finding.
**Action:** structured JSON tool-call log (ISO-8601 ts, case/correlation UUID, tool, params, duration, outcome), redacted, shipped to the agent host / case dir *before* clone destruction. This is the counterpart to the case directory: case dir = findings, audit log = how they were reached.

### C3. Build-your-own MCP wrappers have no secure-coding constraints
**Where:** DEPLOYMENT Phase 5 (capa wrapper, PE/format wrapper), Blueprint §9 (capa-MCP, symbol-MCP, similarity-MCP, verifier-MCP — all "build yourself").
**Gap:** The single largest MCP vulnerability class is command injection / path traversal in tool wrappers (82%/34% in the Endor study), and *every* server you're told to build yourself takes **binary-derived strings and agent-supplied paths and shells out** (`capa -j <path>`, symbol lookups, LIEF over attacker-controlled files). The plans say "thin wrapper, highest value-per-line" but never say *validate inputs, no string-built shell commands, allowlist paths, non-root*. This is the exact surface a malicious sample plus a nudged agent would target.
**Action:** add a secure-wrapper contract to Phase 5: parameterized subprocess only (never string concatenation), path allowlist confined to the case/sample dirs, deny dotfiles, size-cap outputs, structured errors. Run MCP-Scan / MCPSafetyScanner against each self-hosted server (the plan mentions this once in §8 supply-chain — make it a Phase 5 gate).

### C4. No cost / token budget or runaway-spend control
**Where:** Blueprint §6 (notes rate limits/cost in passing), nowhere in DEPLOYMENT.
**Gap:** Long RE sessions plus the verification passes the plan *depends on* burn tokens fast — G Data reports five verification passes still leaving errors, at heavy token cost; Corelight flags cost as a top operational constraint. There's no per-case budget cap, no enforced "bulk annotation → local model, hard reasoning → frontier" routing at the gateway, and no spend kill switch. Without this the lab is either unusable or unboundedly expensive on a real 50MB target.
**Action:** per-case token/$ budget with a hard stop; enforce local-tier routing for bulk rename/describe via LiteLLM (Blueprint already scopes aidapal for this — make it mandatory, not optional); log spend into the audit trail (C2).

### C5. No working kill switch or resource containment for a runaway agent/tool
**Where:** DEPLOYMENT hooks table, Part 6 verification.
**Gap:** Corelight's line — *"a kill switch that actually works when the model is mid-loop"* — has no equivalent here. There are no VM-level CPU/RAM/disk quotas, so a runaway fuzzer, a sample fork-bomb, or an agent stuck in a tool loop can wedge the box (G Data hit exactly this with 32GB thrashing). dan1t0's 15-minute watchdog is cited in the blueprint but not adopted in the plan.
**Action:** hypervisor-level CPU/RAM/disk caps on the clone; a wall-clock watchdog per case that hard-stops the agent and MCP servers; verify the stop actually kills mid-tool-call, not just between calls.

### C6. The verification oracle — the core value — is deferred, not designed
**Where:** Blueprint §9 #4 ("build a differential-testing/emulation verification MCP"), Recommendations Phase 4; DEPLOYMENT verifier.md.
**Gap:** Every benchmark in your own §3 (DecompileBench 52.2% lower correctness; G Data: verdicts are "the worst," 5 passes still wrong) says a real oracle is the thing that makes any of this trustworthy — yet it's the one component left as a future build. The `verifier` agent is defined as read-only + "emulate + cross-check" but has no concrete oracle. G Data's strongest practical finding is the cheapest one available and isn't a first-class pattern in either doc: **have the agent generate a config-extractor / unpacker / decryptor script, then run it against the sample** — the script's success/failure is a genuine feedback loop, unlike prose. (Watch for the agent hardcoding a hallucinated IOC instead of extracting it — cheap to spot-check.)
**Action:** promote "generated-script-with-execution-feedback" to the primary verification mechanism (a `config-extractor` skill + emulation via Unicorn/Qiling/Dumpulator/Speakeasy). Make the verifier's differential-test/emulation MCP a Phase-2 build, not Phase-4 aspiration. Ban VirusTotal-derived verdicts (G Data: models over-rely on scanner results — wrong for exactly the samples you care about).

---

## NICE-TO-HAVE

| # | Gap | Where / why it matters |
|---|-----|------------------------|
| N1 | **No coverage-guided fuzzing or symbolic stack on the dynamic node** | The `vuln-hunter` skill has no fuzzer under it. AIxCC's reusable lesson (your §3) is fuzzers+symbolic+LLM. Add WinAFL (DynamoRIO / TinyInst / Intel-PT) + Jackalope, and angr, to the Windows/Spark tooling and expose as agent tools. Currently vuln-hunting is decompile-and-reason only. |
| N2 | **No SSH / PowerShell MCP into the VM** | G Data found an SSH-to-Windows MCP high-value: run Sysinternals, PowerShell, dynamic .NET deobfuscation, on-the-fly monitoring. Cheap to add, complements x64dbg/WinDbg. |
| N3 | **Network emulation assigned to FakeNet-on-Windows, not a Linux sink** | Blueprint §7.2 cites the FLARE-VM + REMnux two-VM pattern (also G Data's layout); DEPLOYMENT puts FakeNet inside the target VM. A separate INetSim/REMnux sink (or the Spark) is cleaner isolation and gives DNS/HTTP/C2 responses without trusting a service co-resident with the sample. Document the DNS-sink design explicitly. |
| N4 | **Nothing provisions the agent host or the MCP gateway** | The script is VM-only. The WSL2/Spark orchestrator, the Docker MCP Gateway, and LiteLLM are referenced but unprovisioned — a companion bootstrap (even a checklist) closes the loop. In Profile B the agent host is where the real config lives. |
| N5 | **No MCP-server supervision / health heartbeat / auto-restart** | "Set to start correctly" (Phase 5) is vague. A server that dies mid-case silently stalls the agent. Add process supervision (Windows service or scheduled-task keepalive) + a per-case heartbeat check. |
| N6 | **Golden-image lifecycle undefined** | No rebuild cadence, tool-CVE patching policy, image versioning/rollback, or orphan-clone GC. A sealed image drifts out of date; clones accumulate. Especially relevant now that the template is an adopted, hand-built VM (C1). |
| N7 | **No backup/DR or CI for the provisioner itself** | The config repo, `re-lab.lock.json`, `flare-config.xml`, and golden template are single points of failure. Add repo backup + a CI lane that lints the PS1 (`PSScriptAnalyzer`), validates the config schema, and ideally test-runs in a throwaway VM. |
| N8 | **DPAPI portability caveat when cloning** | Phase 5 suggests DPAPI for bearer tokens; DPAPI blobs are machine/user-bound and won't decrypt in a clone. You rotate tokens at clone time (good), but flag that any DPAPI-protected build secret is unusable post-clone by design — don't rely on it surviving. |
| N9 | **Seal doesn't disable clipboard / shared drives / guest-additions clipboard** | Blueprint §7.2 says "no shared clipboard or drives"; Phase 9 seal doesn't enforce it. Cheap escape/contamination vector to close in the seal step. |
| N10 | **Kernel/rootkit/bootkit analysis path deferred** | memoryforensics1/windbg-mcp + KDNET two-VM is out of scope for v1 (reasonable) — just name it as a known limitation so a kernel-mode sample doesn't surprise you. |
| N11 | **Multi-user attribution — confirm N/A** | The MCP-hardening sources push OAuth/per-user identity hard; that's for teams. For a single-operator homelab it's genuinely not needed — state that explicitly so it's a decision, not an omission. |

---

## ADDITIONAL SKILL PACKS & MCPs TO EVALUATE

Tools **not already in `BLUEPRINT.md`** that are worth a look. Several directly fill the "build this yourself" gaps the blueprint names in §9 (capa-MCP, binary-similarity MCP, symbolic/verifier MCP) — meaning you may not have to build them.

> **Vetting caveat first:** every item below is third-party, mostly low-star, recent, single-maintainer. Blueprint §7.3 applies in full — pin to a commit, vendor, read the SKILL.md/wrapper by hand, run MCP-Scan, install into the VM not the host. The all-in-one servers that *emulate or execute* binary code (Arkana, Reversecore, revula) are higher-risk by nature; treat accordingly. Do not let the agent pick these off a search result.

### Fills a blueprint-named "build-your-own" gap
| Tool | Fills | Notes |
|------|-------|-------|
| **Heretek-RE/re-capa** | §9 #1 capa-MCP | Dedicated capa MCP: `detect_capabilities`, `extract_mbc`, `find_interesting`, with ATT&CK/MBC mappings. Exactly the deterministic grounding tool you flagged as unbuilt. Part of a broader **Heretek-RE / RE-AI** suite (`re-angr`, `re-triton`, `re-rizin`, `re-mba-deobfuscate`) whose design explicitly cross-validates symbolic results between angr and Triton — i.e. a ready-made verifier pattern (C6). |
| **infragate/capa** (unrelated to Mandiant capa — it's an MCP gateway) | N5 supervision + C4 token cost | An MCP **gateway** with OAuth 2.1/PKCE, subprocess health monitoring + graceful termination, and `setup_tools`/`call_tool` meta-tools for **on-demand tool loading to cut token overhead**. A concrete option for the gateway layer that also addresses server supervision and context bloat. |
| **JameZUK/Arkana** (`PeMCP`, ~33★) | §9 #1, #3, #4 + N1 | 294 tools in one server: angr symbolic exec/decompile (46), Qiling+Speakeasy emulation, **BSim-style cross-binary function similarity** (the similarity-MCP gap), 29-tool step-through debugger, Binary Refinery 200+ transforms, .NET deobf, Frida script-gen, VMProtect/Themida pipeline. Broadest single-server option; also the biggest trust surface — it emulates sample code. |
| **sandbornm/angr_mcp** / official **`angr.mcp`** | N1 symbolic | angr symbolic execution + CFG as MCP. The official `angr.mcp` server now ships in angr itself — the low-risk way to add symbolic execution to the verifier. |

### Windows / dynamic-node aligned (relevant to your FLARE-VM box)
| Tool | Why |
|------|-----|
| **mistyy77/rikune** | Purpose-built **Windows** RE MCP: PE triage, DLL/COM profiling, Rust/.NET recovery, `malware.config.extract`, `c2.extract`, `unpack.guide` (UPX/Themida/VMProtect/.NET Reactor/ConfuserEx), symbolic via angr/Z3. Closest match to your dynamic-node role. |
| **HiyokoSauna37/claudecode-re-toolkit** | Claude Code **skills** (not just MCP): `ghidra-headless` (8-phase pipeline w/ capa/FLOSS/oletools), `malware-sandbox` (VMware + Frida + FakeNet + **x64dbg-automate MCP** + dumpulator + auto snapshot-revert + Host-Only isolation + `--anti-vm` VMX hardening), `threat-intel` (17 OSINT services), `malware-fetch`. Its sandbox skill mirrors your Profile-B workflow closely — good reference even if you don't adopt it. |
| **kd992102/rizin-mcp** | rizin + RzGhidra (`pdg`) + capa in one server, with background-job capa + resource-table type-mismatch detection (embedded-file signal). Lean headless static second opinion. |
| **coffeegrind123/ghidra-in-claude-code** | Turnkey headless launcher wiring **bethington/ghidra-mcp v5 (245 tools)** into Claude Code — the 200+-tool fork the blueprint mentions but doesn't wire up. Convention enforcement + plate-comment quality gate. |

### Discovery surfaces & CTF
| Tool | Why |
|------|-----|
| **FuzzingLabs/mcp-security-hub** | 38 Dockerized, **non-root, Trivy-scanned** MCP servers (capa, yara, binwalk, radare2, ida, virustotal, +fuzzing). The production-hardening posture is itself a model for C3/§7.3; cherry-pick individual containers. |
| **crowdere/Awesome-RE-MCP** | Curated index of RE MCP servers (incl. GDB MCP implementations) — a cleaner discovery surface than searching, complements `gmh5225/awesome-skills`. |
| **Coff0xc/CTF-MCP** (126 tools) / **president-xd/revula** (GDB/QEMU/ROP/pwntools) | Only if CTF/pwn is in scope. revula adds ROP-chain build + pwntools PoC gen; both Linux-exploitation-leaning, tangential to Windows malware. |

**Recommendation:** for immediate value with least risk, evaluate **re-capa** (grounding), **angr.mcp** or **re-angr/re-triton** (symbolic + the built-in cross-validation = your C6 oracle), and **rikune** or **claudecode-re-toolkit** (Windows dynamic node). Hold the mega-servers (Arkana/Reversecore/revula) until after a hand review — their breadth is real but so is their execute-the-sample surface.

---

## SKILL LAYER — packs that assume the MCP is already connected

The blueprint catalogs MCP *servers* well but is thin on the *skill* layer that drives an already-wired MCP (the SKILL.md methodology, not the tools). These are the per-tool skill packs worth pulling into `.claude/skills/` once the corresponding server is connected. Same §7.3 vetting applies — pin commits, read the SKILL.md by hand; several of these are single-author and some tools carry many near-identical forks (see x64dbg).

### Ghidra (assumes GhidraMCP / PyGhidra / ReVa connected)
| Pack | Why it's worth it |
|------|-------------------|
| **GeReV/ghidra-iterative-re** ⭐ | The most sophisticated Ghidra *methodology* skill found — and it directly attacks your **C6 verification problem**. Encodes the iterative read→infer→re-read loop and its failure mode: **you can corroborate your own guesses** (apply an AI inference, re-read, and the confirming read looks independent when it isn't). Enforces a `SourceType.AI` trust model (harvest evidence *excluding* AI-sourced names or a second pass eats its own output), **invariant bracketing** (Ghidra silently destroys unrelated functions — diff a whole-program invariant across every mutation and raise on any unaccounted change), and assertion discipline (every check demonstrated *failing* before it counts). Derived and corrected over a real ~5,600-function project. Plain-Markdown, harness-agnostic. Adopt its trust model into your `CLAUDE.md` even if you don't take the whole skill. |
| **cyberkaida ReVa skills** (`binary-triage`, `deep-analysis`) | Already in blueprint via ReVa, but the concrete skills are the reference for breadth-first triage → depth-first investigation loop (READ→UNDERSTAND→IMPROVE→VERIFY→FOLLOW→TRACK), with per-question strategies ("does this use crypto?", "what is the C2?"). DB writes require approval. Good template to copy. |
| **majiayu000/claude-skill-registry → reverse-engineering** | Generic multi-MCP SKILL.md (Ghidra/IDA/r2/angr) with malware / vuln-research / CTF workflow recipes. Lighter than the above; useful as a routing skeleton. |

### WinDbg (assumes a WinDbg MCP connected)
| Pack | Why |
|------|-----|
| **glslang/windbg-mcp** (server **+ bundled `windbg-debugging` skill**) ⭐ | Not in the blueprint's WinDbg list and arguably the best-engineered new one. Rust/DbgEng-native, single-plugin Claude Code marketplace that registers the server **and** a skill with setup/crash-dump/live-kernel/TTD playbooks. Real TTD nav (`step_back`, `reverse_go`, `goto_position`), `ttd_calls`/`ttd_memory`/`ttd_events` over the TTD data model, driver-IOCTL tools, pool/heap census. **Critical gotchas its skill documents** (that bite any WinDbg-MCP setup, incl. your Phase 4): System32's in-box `dbgeng.dll` rejects `.run` TTD replay (`0x80070057`) and has no `!analyze` (needs `winext\`) — you must bundle the full WinDbg engine next to the binary, and use `!ext.analyze -v` not `!analyze`. Feed these into your symbol/TTD provisioning. |
| **svnscha/mcp-windbg** (Claude plugin: **4 skills + `crash-analyst` agent**) | Blueprint has the server but not its skill layer — the plugin install adds four skills and an agent with symbols preconfigured. This is the "best general-purpose default" the blueprint already picks; wire the skills, not just the tools. |
| **Devolutions/windbg-tool** | New, **vendor-maintained** (better supply-chain footing than single-author repos) Windows-first CLI **+** MCP: TTD replay/record, dump triage, stable JSON envelopes, and shipped agent prompt templates + `recipes`/`discover` for tool discovery. The JSON-CLI-alongside-MCP shape is easy to sandbox/rate-limit. |
| **fenzel999/dotnet-artisan → dotnet-debugging** | A WinDbg-MCP-driven SKILL.md for **managed/.NET** targets (SOS command packs: `!clrstack`, `!dumpheap`, `!gcroot`, `!syncblk`, `!dlk`, `!runaway`), with crash/hang/high-CPU/memory/kernel triage routes and a report template. Directly relevant since Windows targets are frequently .NET (dnSpyEx/ILSpy in your Phase 3). |

### x64dbg (assumes duty1g or dariushoule x64dbg MCP connected)
- **dariushoule/x64dbg-skills** is already your pick (8 skills). Two things the blueprint doesn't capture: (1) the **ZMQ single-client lifecycle** — skills disconnect the MCP client before running raw `x64dbg_automate` Python, then reconnect (only one client at a time); replicate this in any x64dbg skill you write. (2) There are **many near-identical forks** (`redpack-kr`, `Janwiao`, `Neoncat-OG`, `IULOVE`, …) — a textbook §7.3 trap. **Pin the upstream `dariushoule` repo at a commit; do not let the agent grab a fork off search.** `/find-oep` covers Themida/VMProtect/Enigma with anti-debug evasion; `/decompile` drives angr; `/vuln-hunter` runs recon→triage→bug-hunt→PoC.

### Binary Ninja (assumes a BN MCP / Sidekick connected)
- **There is no strong community "assumes BN-MCP connected" *skill* pack** equivalent to x64dbg-skills — the BN skill layer lives mostly inside **Sidekick** (commercial). Sidekick ships a curated **Skills catalog** (reusable playbooks keyed to goal+artifact — "hunt UAF in C++", "triage ransomware", "recover types in a stripped Go binary"), specialist modes (Research / Transform / Repair / Modeling / Automation), a **Library** of scripts/agents/skills invocable as slash commands, and **BNQL** with `concept()` semantic search and `path()`/`reachable-from`/`callers` call-graph queries — and as of Sidekick 26 it is itself an MCP client. If you're paying for Binary Ninja, its skill/Library/BNQL layer is more mature than anything free.
- **PetoWorks/binaryninja-mcp** — a BN MCP not in the blueprint's list (which has fosdickio / BinAssistMCP / bn_cline_mcp): auto-setup for Claude Code, multi-binary switching, and a `query_sidekick` tool that bridges the free MCP to Sidekick as an execution sub-agent. Ships a CTF methodology prompt. Reasonable free BN entry point.
- **Practical takeaway:** on the free tier, drive BN with a *general* RE skill (e.g. the majiayu000 one, or port GeReV's methodology) rather than expecting a BN-specific pack. Reserve the polished skill experience for Sidekick if licensed.

---

## TECHNIQUE-SPECIFIC SKILLS — program mapping, dataflow, tracing, symbolic execution

Skills/prompts mapped to the RE techniques you named. Two caveats up front: (1) several of the strongest **program-mapping / taint / control-flow** skills are written for *source trees*, not stripped binaries — the methodology and output contracts port cleanly to RE (feed them decompiler output / a program graph), but they are not turnkey on a raw PE; (2) same §7.3 vetting applies. Standouts marked ⭐.

### Map out a program · architecture review · control-flow
| Skill | What it does |
|-------|--------------|
| **NickCrew `architectural-analysis`** ⭐ | Eight modes in one skill — information architecture, **data flow**, integrations, UI surfaces, interaction patterns, data model, **control flow**, **failure modes** — each producing a mermaid diagram where **every node/edge resolves to a `path:line` citation**, dispatched as parallel sub-agents and **mechanically verified before any node lands** (confirms/drift/gap/extends contract). This is the citation-grounded, verify-before-assert discipline your C6 gap wants, applied to architecture. Source-oriented; point it at decompiled output. |
| **beadnall `codemap`** | Turns a codebase into an explorable isometric architecture diagram + component index with data moving along edges. Good for the "map this out for a human" deliverable; lighter than the above. |
| **`binary-re`** (research plugin, ClaudePluginHub) | A *binary-native* phased RE skill (triage → static → dynamic → report) over r2 + Ghidra-headless + QEMU + GDB + Frida, hypothesis-driven with evidence chains and human-in-the-loop gates. ELF/embedded-leaning (ARM/MIPS/x86) but the closest turnkey "map an unknown binary" skill. |

### Source-to-sink · sink-to-source · taint · call-path · blast radius
| Skill | What it does |
|-------|--------------|
| **Trail of Bits `trailmark`** ⭐ (plus the whole ToB marketplace) | Vendor-maintained Claude Code plugin that builds **multi-language source *and* binary code graphs** for security analysis: call-path mapping, **attack-surface / taint-propagation tracking**, blast-radius, Mermaid call/data-flow diagrams, graph-sliced context packets for constrained subagents, **structural diff gating** between commits, and **variant expansion** of confirmed bugs. The marketplace also ships `static-analysis` (CodeQL/Semgrep/SARIF), `variant-analysis`, `differential-review`, `fp-check` (false-positive gate), and `testing-handbook-skills` (fuzzers/sanitizers/**coverage**). Best-engineered, best-supply-chain option in this whole document. |
| **`build-program-graph`** ⭐ | Standalone skill (Trailmark-backed): builds a program graph and runs four preanalysis passes — **blast-radius**, entrypoint enumeration by trust level, **privilege-boundary detection**, and **taint propagation (forward from untrusted entrypoints)** — then answers callers/callees, source→sink paths, transitive slices (ancestors = sink-to-source, descendants = source-to-sink), complexity hotspots, and `attack_surface()`. Crucially it **bounds its claims**: "reachability is not taint; verify data flow by hand before claiming it" — exactly the honesty your verifier needs. |

### Tracing · hooking · dynamic instrumentation · coverage analysis
| Skill | What it does |
|-------|--------------|
| **Rudra-ravi `frida-skills`** ⭐ | 13-skill model-agnostic Frida pack: `frida-workflow`, `frida-tracing-discovery` (classes/methods/modules/exports/**call paths** before hooking), `frida-native-hooks` (Interceptor / **Stalker** / NativeCallback / CModule), Android/iOS hooks, `frida-tls-pinning`, `frida-anti-instrumentation` (anti-Frida/anti-debug bypass), `frida-script-review` (harden public scripts before running — good hygiene). Ethos: observe before mutate, small reversible hooks, version checks. |
| **sandbornm `frida-instrument`** | Single tight SKILL.md with bundled scripts: enumerate-all, `trace_calls`, `hook_functions`, `scan_memory`, and **`stalker_trace` for instruction-level coverage / control-flow recovery**. Notes the Frida-static + angr-CFG-then-validate-at-runtime combo. |
| **as0ler `skills`** | radare2 + **frida** + **r2frida** (+ a UE5 internals pack) — the r2frida skill is the clean "attach, hook, trace, dump memory on a live/obfuscated target" workflow. |
| **hypnguyen1209 `offensive-claude` → dynamic-instrumentation reference** | A single reference doc that clusters DBI (Frida/Pin/DynamoRIO), **Stalker coverage**, debuggers, and symbolic/concolic engines, with Frida-17 anti-RASP OPSEC and a "what each touches" (Frida injects/loud, symbolic = silent) table. Good mental model to fold into a CLAUDE.md. |

### Symbolic execution
| Skill | What it does |
|-------|--------------|
| **yaklang/hack-skills `symbolic-execution-tools`** ⭐ | The best dedicated symbolic-exec **playbook** found: angr + Z3 + Unicorn (+ Qiling) with a tool-selection decision tree, 15+ ready angr patterns, SimProcedure/hook templates for `scanf`/`printf`/`malloc`/`strcmp`, symbolic stdin/argv/file setup, **path-explosion management** (veritesting, DFS, constrain-and-avoid), and a pitfalls table. Explicitly exists because base models emit broken angr scripts — which is exactly your local-model failure mode. Pairs with `anti-debugging-techniques` and `code-obfuscation-deobfuscation` skills in the same repo. |
| **angr's own CTF-solving guide + `angr-examples`** | Canonical worked keygen/crackme/serial patterns (`call_state` + `explore(find=eax!=0)`, reduce-keyspace-then-brute-force). Vendor docs; safest reference to vendor alongside the playbook. Complements the **re-angr/re-triton** cross-validation MCPs from the earlier section. |

### String analysis · debug symbols / PDBs
- Mostly **covered by tools inside the general packs, not dedicated skills**: `wshobson/reverse-engineer` (already in blueprint) explicitly wires **strings/FLOSS**, `nm`/`c++filt` demangling, and DIE; `hackersifu/re-ioc-extraction` (earlier section) is the string→IOC skill; `binary-re` covers rabin2 string/architecture fingerprinting. **Gap stands:** no dedicated **PDB / symbol-server / FLIRT-Lumina recovery** skill surfaced — this remains the blueprint's §9 #2 build-your-own item and your GAP `pdbsql`-adjacent gap. Worth writing a small `symbol-recovery` skill (fetch from msdl, apply, FLIRT for library code) yourself.

### Discovery indexes worth bookmarking
- **ram-elgov/awesome-llm-reverse-engineering** (curated LLM-RE tools/papers/datasets), **mrphrazer/reverser_ai** (local-LLM auto-rename/annotation, offline), and Cisco Talos's "Using LLMs as a reverse engineering sidekick" write-up (practical MCP + local-model findings). Complements `gmh5225/awesome-skills` and `crowdere/Awesome-RE-MCP` from earlier.

**Net:** for your list, the highest-value adds are **ToB trailmark / build-program-graph** (source-to-sink, sink-to-source, blast radius, coverage, with honest claim-bounding), **NickCrew architectural-analysis** (verified control-flow/data-flow/failure-mode mapping), **Rudra-ravi frida-skills** (hooking/tracing/coverage), and **yaklang symbolic-execution-tools** (angr/Z3/Unicorn). The one real hole across everything surveyed is a dedicated **PDB/symbol-recovery** skill — build it.

---

## DIRECT GITHUB SEARCH (gh, star-ranked, 2026-09-03)

Searched GitHub directly across every topic in this session. Results below are **new or newly-relevant** vs. the blueprint; low-star/very-recent repos are included where the capability is notable, but treat anything under a few hundred stars as unvetted (§7.3 — pin, read, scan). Note: literal queries like "taint analysis mcp" / "symbolic execution mcp" returned **nothing** — those capabilities aren't standalone repos, they're bundled inside the multi-tool servers below (minusOne, Arkana, Reversecore).

### The single most relevant find
- **2akouwu/reverify** — **737★**, updated daily. *"AI makes things up when it reads a binary. Reverify checks its every claim against the real bytes… LLM proposes, deterministic tools verify. MCP server + CLI."* Topics: mcp, binary-analysis, frida, capstone, unicorn, **hallucination, verification**. **This is your C6 verification oracle as a shipping product** — evaluate it before building your own. Highest-value single result of the whole session.

### Windows lab / deployment-relevant
- **totekuh/winbox** — isolated **Windows vulnerability-research platform for AI agents**: VM automation, hypervisor debugging, driver/IPC testing, containment, MCP. This is roughly what `DEPLOYMENT_PLAN.md` describes — worth reading as prior art even if you don't adopt it.
- **gl0bal01/malware-analysis-claude-skills** — **45★**, 5 Claude skills (triage, dynamic, detection-engineering, reporting) explicitly built for **offline REMnux/FLARE-VM** — directly aligned with your existing-FLARE-VM setup.
- **Xiaobocai08/system-informer-mcp** — native C MCP giving an agent process/handle/memory control via System Informer; a lighter dynamic-introspection option than a full debugger.

### One-server-covers-the-technique-list
- **Ashibalt/minusOne-mcp-reverse** — **77 semantic operations** in one MCP: static triage, unpacking, decompilation (Ghidra/IDA), **frida/TTD dynamic**, **Unicorn emulation**, **angr symbolic execution**, evidence handling. Maps almost 1:1 onto the techniques you listed; newer/low-star so vet hard, but the coverage is exactly on-target.

### Disassembler MCP servers not in the blueprint (higher-star)
| Repo | ★ | Note |
|------|----|------|
| **bethington/ghidra-mcp** | 3672 | The 200+-tool Ghidra fork (GUI + headless) the blueprint alludes to — confirmed large and active. |
| **P4nda0s/IDA-NO-MCP** | 1964 | Popular lightweight/low-latency alternative to ida-pro-mcp's verbose interaction. |
| **blacktop/ida-mcp-rs** | 775 | **Headless IDA (Rust, idalib)** — clean fit for your gateway/headless path (blueprint's idalib note). |
| **MeroZemory/ida-multi-mcp** / **axelmierczuk/tenrec** | 409 / 179 | Multi-instance / multi-session IDA — cross-binary analysis (EXE + several DLLs at once). |
| **fission-systems/Fission** | 10 | Rust RE workspace, Ghidra SLEIGH lifting + NIR/HIR structuring + AI UIs — one to watch. |

### WinDbg MCPs beyond the blueprint's four
- **kanren3/windbg-mcp-rs** (54★, Rust plugin turning a live session into an MCP server), **themixednuts/windbg-mcp-server** (24★), **chensiling/Windbg-MCP** (intent-driven, 19 structured tools over cdb). Adds to svnscha / memoryforensics1 / gengstah / glslang.

### Reference harnesses (Blazytko-style, copyable)
- **Veedubin/Reverse-Engineering-Playground** — self-contained AI RE lab: **15 specialist agents**, Ghidra MCP (245 tools) + radare2-mcp, **semantic memory**, cross-distro installer, multi-provider LLM. A concrete multi-agent topology to study.

### Mobile (if in scope; otherwise skip)
- **incogbyte/android-reverse-engineering-claude-skill** (111★) and **iOS-reverse-engineering-claude-skill** (88★), **Fausto-404/ai-mobile-reverse-skills** (152★, 6-phase JADX-MCP orchestrator), **anatoly505/ios-reverse-skills**. Well-starred but off-axis for Windows PE work.

### Adjacent / web (note only)
- **js-reverse-mcp** (2672★) — headed-Chrome JS reverse-engineering MCP; irrelevant to PE malware but the highest-starred RE-MCP found, worth knowing if web targets ever enter scope.

**Takeaway from the direct search:** three finds change your build math — **reverify** (adopt as the C6 oracle instead of building), **minusOne-mcp-reverse** (one server spanning static/dynamic/emulation/symbolic — a fast way to cover the technique list, pending a security review), and **gl0bal01's FLARE-VM/REMnux skills** (aligned with your actual environment). Everything else is incremental server/skill choices.

---

## Bottom line

Nothing here undermines the architecture — it's well-reasoned and current. The critical items cluster around **operational trustworthiness** (audit trail C2, verification oracle C6, cost/kill-switch C4/C5) and **the change of starting point** (adopting a used FLARE-VM, C1), plus one concrete security hole in the build-your-own wrappers (C3). Address C1 before you touch the existing VM; land C2/C6 before you trust a single verdict; C3/C4/C5 before any unattended run.
