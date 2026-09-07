# Dump Workflow

> **Quick Ref**: Open dump -> !analyze -v -> classify (crash/hang/memory/CPU) -> load task-specific playbook -> check symbols -> diagnose -> report | Always capture EXCEPTION_POINTERS | Verify dump is not corrupted before analysis

## Purpose
Analyze a saved dump when live attach is not available (live attach is disabled on this host
regardless -- see `references/live-attach.md`).

## Steps
1. Confirm dump path.
2. Open dump with `open_cdb_dump`.
3. Run baseline commands via `run_cdb_command`:
- `!analyze -v`
- `lm`
- `~* kb`
4. Run scenario command pack based on symptom.
5. Close with `close_cdb_session`.

## Notes
- For intermittent hangs, two dumps 20-30 seconds apart improve confidence.
- Prefer full dumps when possible for complete stack/module context.
