# Task: Kernel Triage

> **Quick Ref**: Kernel dumps need different approach | !process to find target process | .process /r to switch | Check IRQL for driver issues | !analyze -v may work differently | Rarely needed for .NET (user-mode is sufficient)

## When To Use
- BSOD/bugcheck analysis of a static kernel-mode dump file, opened like any other dump with
  `open_cdb_dump` -- this is the enabled path.
- A *live* kernel remote-debug session (KDNET/named pipe/serial) is a different, currently
  disabled capability -- see `windbg-kernel-debug` under `skills[windbg]` in
  `re-agent.config.json`. Do not attempt it; say the capability is disabled if asked for it.

## Commands
- `!analyze -v`
- `k`
- `lm`
- `!thread`
- `!process 0 1`

## Deliver
- Bugcheck or kernel fault summary.
- Faulting stack and likely driver/module.
- Confidence and next capture steps.

## Guardrail
If only user-mode evidence is available, state that kernel conclusions are limited.
