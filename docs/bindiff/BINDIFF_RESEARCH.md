Coverage is strong — synthesizing. Report follows.

---

# Deep Research: Agentic Reverse Engineering & Patch Diffing with Claude Code / Codex

**Summary:** Agentic patch diffing went from speculative to demonstrated in 2026. The dominant architecture is now settled and consistent across every serious source: a **headless binary-diff engine** (overwhelmingly Ghidra + `ghidriff`) produces a function-level diff, which is fed as *pre-computed context* to an LLM agent that reasons about root cause, then validates hypotheses against a live lab [1][2][4][5]. Anthropic's own Frontier Red Team used exactly this stack — Ghidra decompilation + `ghidriff` diffs — to autonomously build 8 working exploits from 21 Windows kernel patches [1][2]. For your framework, the highest-value additions are a **Ghidra MCP server built for automation** (`pyghidra-mcp`), **`ghidriff` as a plain CLI tool** (not MCP), and a set of **RE Agent Skills** — a pattern now explicitly taught for Claude Code/OpenCode [6][7]. A key architectural finding: the diff engine and the agent are *separate* — the differ runs offline and its output is staged as files, which fits your MCP-plus-skills model cleanly.

## Findings

- **[confirmed] The reference architecture is "diff offline, reason online."** Anthropic pre-computed Ghidra + Ghidriff outputs offline (~2 hours for all files) and staged them as files the agent reads at launch; the agent never ran the differ itself [1][2]. Patch2Vuln uses the identical split — a resumable pipeline extracts ELF pairs, diffs with Ghidra+Ghidriff, ranks changed functions, *then* hands dossiers to the agent [4]. This matters for your design: the differ is a batch tool, not an interactive MCP call.

- **[confirmed] `ghidriff` is the de-facto patch-diff engine for agentic work.** Command-line Ghidra diffing engine, 802 stars, GPLv3, `pyghidra`-based, three matching engines (`VersionTrackingDiff` is default/fastest), JSON + markdown output, diffs a full Windows kernel in <1 minute post-analysis [3]. Anthropic's N-day research used it directly [1][2]; Patch2Vuln uses it as its differ [4]. No Ghidra license needed.

- **[confirmed] Claude Code is already being used end-to-end for real patch-to-exploit work.** The PaperCut NG writeup (Aug 2026): 10 prompts, 293 tool calls, 90 minutes, Opus, took a public patch → identified 3 vulns → full unauthenticated RCE chain → then found a bypass of the *emergency* patch overnight [5]. The harness ran in code-server for isolation with custom Skills (Binary-Analysis, Note-Keeper, Finding-Reviewer, Report-Writer) and Ghidra/ILSpy + semgrep + Playwright + Proxmox MCPs [5].

- **[confirmed] "Agent Skills" for RE is now a taught, first-class pattern for coding agents.** The Recon 2026 workshop teaches building custom RE Skills with Claude Code, OpenCode, and Mistral Vibe — structured instruction/script/resource bundles with "workflow capture and progressive disclosure" to cut context overhead on multi-step RE tasks (e.g. IOCTL mapping, dispatch analysis) [6]. This is the direct upstream for the "skills half" of your question.

- **[confirmed] Ghidra MCP servers are abundant and maturing fast; IDA has caught up.** LaurieWired/GhidraMCP (2450+ stars) is the popular general one [8]; `pyghidra-mcp` is the headless, project-wide, multi-binary one purpose-built for agentic/automation workflows [9]; bethington/ghidra-mcp claims 200+ tools with batch operations and Docker [8]. On the IDA side, `mrexodia/ida-pro-mcp` is the reference (headless `idalib-mcp` supervisor model, lists Claude Code + Codex as supported clients) [ida-pro-mcp]; multi-backend `re-mcp` exposes IDA *and* Ghidra behind one portable tool interface [re-mcp].

- **[probable] Multi-agent decomposition beats a single agent for root-cause analysis.** Akamai's PatchDiff-AI fragments Patch Tuesday RCA into micro-tasks across specialized agents (Windows-internals reasoning, RE workflow, vuln-specific analysis) and reports "meaningful accuracy at reasonable cost" [10]. Single-vendor result, but it aligns with the orchestrator/subagent pattern your framework already has.

- **[probable] The binary differ — not the model — is the current bottleneck.** Patch2Vuln localized the right function in only 10/20 security pairs; 6 of the 10 failures happened *before* the model reasoned at all, because the differ/ranker omitted the correct function [4]. Behavioral validation was also weak (2 minimized differentials, zero crash/sanitizer proofs) [4]. Implication: investment in diff quality and function-ranking pays off more than prompt tuning.

- **[speculative] Prompting the agent toward relational/bulk queries materially changes tool efficiency.** The `idamcp` gateway authors note LLMs default to sequential single-purpose tool calls (`list_functions`, `get_xrefs`) and recommend a system-prompt nudge toward a bulk `sql_query` tool [inferred from idamcp README]. Plausible and mechanism-consistent, but single-source and self-reported.

## Synthesis

- **The whole field converged on one shape**, and it's the shape your repo already fits: an MCP server exposing the decompiler's live database + a CLI differ + skills that encode the workflow + a lab for validation. Anthropic, Patch2Vuln, PaperCut, and ClearSecLabs's training all describe the same loop with different emphasis [1][2][4][5][6]. That convergence is itself the strongest signal on what to build.

- **Two things are deliberately kept separate** in every mature setup: the *diff engine* (batch, offline, file output) and the *analysis agent* (interactive, MCP-driven). Don't wrap `ghidriff` in an MCP tool — run it as a CLI step that writes JSON/markdown, then let the agent read those files. This is explicit in Anthropic's staging approach [1] and Patch2Vuln's pipeline [4].

- **Contradiction chased:** popular press frames this as "AI finds 0-days in 31 minutes" [happyrock/cybersecurityinstitute], while the primary research is markedly more sober — Patch2Vuln's honest 10/20 localization and zero memory-corruption proofs [4], and even Anthropic's headline is *N-day* (patch already public), not 0-day, with validation-heavy grading [1][2]. The gap is real: the secondary/press sources overstate autonomy. Weight the primaries.

- **Gap:** I found no open-source, ready-made "patch-diffing **skill**" that packages the ghidriff→triage→validate loop for Claude Code. The pieces exist (ghidriff, the MCP servers, the taught pattern) but assembling them into a skill is net-new work — which is precisely the opportunity for your framework.

## Prior art in code

- `clearbluejar/ghidriff` — CLI Ghidra patch-diff engine, 802★. https://github.com/clearbluejar/ghidriff [3]
- `clearbluejar/pyghidra-mcp` — headless, project-wide, multi-binary Ghidra MCP for agentic workflows. https://github.com/clearbluejar/pyghidra-mcp [9]
- `LaurieWired/GhidraMCP` — most popular general Ghidra MCP, 2450★. https://github.com/LaurieWired/GhidraMCP [8]
- `mrexodia/ida-pro-mcp` — reference IDA MCP (headless `idalib-mcp`), lists Claude Code + Codex as clients. https://github.com/mrexodia/ida-pro-mcp
- `re-mcp` (jtsylve) — multi-backend IDA **and** Ghidra behind one portable tool interface. https://github.com/jtsylve/ida-mcp
- `radareorg/radare2-mcp` — official radare2 MCP (no license cost). https://github.com/radareorg/radare2-mcp
- `bethington/ghidra-mcp` — 200+ tools, batch ops, Docker. https://github.com/bethington/ghidra-mcp
- No open patch-diffing *skill* found — see gap above.

## Ideas & Recommendations (for your agent-shell framework)

1. **Add a `reverse-engineering` variant, not a default-tier MCP.** — RE tooling needs Ghidra/JDK/IDA on the box, so it belongs in a variant (like your new `vault`/`firecrawl` ones), `requiresImage: "base"` plus a Docker stage that installs Ghidra + JDK 21. Bundle `pyghidra-mcp` as its `mcpServer`. Confidence: high. Next step: `variants/reverse-engineering/variant.json` + a `FROM base AS re` stage.

2. **Ship `ghidriff` as a CLI tool in that variant, not an MCP tool.** — Every mature pipeline keeps the differ as a batch step writing JSON/markdown [1][4]. Install it in the stage; let skills invoke it via Bash and read the output files. Confidence: high (directly attested by two primaries).

3. **Write a `patch-diff` skill encoding the loop** — extract old/new binaries → run `ghidriff` → rank/triage changed functions → form root-cause hypothesis → validate in a lab. This is the missing artifact; the pattern is taught but unpackaged [6]. Model it on the PaperCut harness's skill set (Binary-Analysis, Finding-Reviewer, Report-Writer) [5]. Confidence: high value, net-new.

4. **Fan-out matches your orchestrator.** PatchDiff-AI's specialized-agent split [10] maps onto subagents: one drives the differ/ranker, one reasons root cause, one validates PoCs in the lab. Reuse your `research-deep` fan-out shape. Confidence: probable.

5. **Invest in function ranking over prompts.** The bottleneck is diff coverage, not model reasoning [4]. A ranking heuristic (changed + security-relevant strings/xrefs first) will move accuracy more than prompt tuning. Confidence: probable.

6. **Codex parity:** all the major MCP servers list Codex as a supported client [ida-pro-mcp], and you just fixed Codex MCP registration — so the same variant serves Codex with no extra work. Confidence: high.

**Coverage:** Lanes run — **GitHub** (via Exa `site:github.com` + Brave; the gateway's dedicated `firecrawl_research_search_github` returned 404, so this lane ran degraded — no indexed issue/PR search, repo-level only); **keyword web** (Brave, 3 queries); **semantic web** (Exa, 3 queries); **papers** (Patch2Vuln located and read in full via arXiv scrape; the gateway's `firecrawl_research_search_papers` 404'd, so no systematic paper sweep — other relevant papers may exist unfound); **site reads** (3 primary sources scraped in full: Anthropic N-days, techanarchy PaperCut, ghidriff README). Lanes skipped — **Context7 docs** (these are niche security tools, not library docs Context7 indexes); **Tavily agentic sweep** (timed out on first call, not retried). Effective successful tool calls: ~15. **Degradation to flag:** two gateway sub-tools (Firecrawl GitHub + papers search) are unavailable on your gateway, so "no patch-diffing skill exists" is *probable, not confirmed* — it rests on repo-level search, not indexed-code search. Worth a re-run once those endpoints are fixed.

## References

[1] Anthropic Frontier Red Team, "N-days" — used Ghidra decompilation + Ghidriff function-level diffs as agent inputs; 8/21 Windows kernel exploit chains. https://red.anthropic.com/2026/n-days/
[2] Anthropic, "Measuring LLMs' impact on N-day exploits" (Jun 8 2026) — primary writeup, offline-staged Ghidra/Ghidriff, agentic grader. https://www.anthropic.com/research/n-days
[3] `clearbluejar/ghidriff` — CLI Ghidra binary diffing engine, 802★, VersionTrackingDiff, JSON/markdown output. https://github.com/clearbluejar/ghidriff
[4] David & Gervais, "Patch2Vuln: Agentic Reconstruction of Vulnerabilities from Linux Distribution Binary Patches," arXiv:2605.06601 (May 2026) — pipeline structure + honest failure analysis. https://arxiv.org/abs/2605.06601
[5] Kev Breen (TechAnarchy), "From Patch to Exploit: Using Claude Code to reverse engineer a zero-day in PaperCut NG" (Aug 2026) — full Claude Code RE harness, skills + MCP list. https://techanarchy.net/from-patch-to-exploit-using-claude-code-to-reverse-engineer-a-zero-day-in-papercut-ng/
[6] Recon 2026, "Agentic Reverse Engineering: Building Custom AI Skills with Coding Agents" (McIntosh/ClearSecLabs) — RE Skills for Claude Code/OpenCode. https://cfp.recon.cx/recon-2026/talk/SHYHKM/
[7] Ringzer0 / ClearSecLabs, "Building Agentic RE" — course; source of the Anthropic-used-ghidriff attribution, corroborated by [1][2]. https://ringzer0.training/countermeasure-fall-2026-building-agentic-re-automating-reverse-engineering-vulnerability-research-with-ai/
[8] `LaurieWired/GhidraMCP` (2450★) + `bethington/ghidra-mcp` (200+ tools). https://github.com/LaurieWired/GhidraMCP
[9] clearbluejar, "pyghidra-mcp: Headless Ghidra MCP Server for Project-Wide, Multi-Binary Analysis." https://clearbluejar.github.io/posts/pyghidra-mcp-headless-ghidra-mcp-server-for-project-wide-multi-binary-analysis/
[10] Akamai, "Patch Wednesday: Root Cause Analysis with LLMs" — PatchDiff-AI multi-agent RCA. https://www.akamai.com/blog/security-research/patch-wednesday-root-cause-analysis-with-llms

---

The deep tier worked end-to-end: hook fired → skill loaded → decomposed → fanned out → cross-referenced → confidence-tiered → Coverage was loud about the two 404'd gateway lanes. One real finding for your own setup: **`firecrawl_research_search_github` and `firecrawl_research_search_papers` return 404 on your gateway** — the Firecrawl provider's research sub-tools aren't wired up, and Tavily timed out on a `pro` call. Web/Exa/scrape carried it, but the GitHub lane ran degraded. Worth checking the MCPJungle `research` group config if you want those lanes at full strength. Want me to look into that, or turn recommendation #1–3 (the `reverse-engineering` variant + patch-diff skill) into actual files?