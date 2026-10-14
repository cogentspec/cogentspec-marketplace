---
name: gptpop
description: Compatibility alias for $gptsnap, the CogentSpec external-browser split-screen workspace.
---

# Compatibility alias for GPTSnap

`$gptpop` is the legacy alias for `$gptsnap`. Read `../gptsnap/SKILL.md` and follow its external-browser split-screen workflow exactly once. Do not run the generic Popout or GPTDesk launcher first. The alias shares the same isolated context, Bridge and destination as `$gptsnap`; it does not open a retained Popout.

## Explicit user-requested Popout sizing

Window sizing is independent of connection. Only when the user explicitly asks to resize or normalize GPTPop or the Claude window, invoke `../cogentspec/scripts/popout-window-normalizer.ps1` from the invoking workspace. Do not run the Bridge connection sequence unless the user also requested a connection.

- Default to `-Mode Widget -Width 900 -Height 600 -Target both -AllowClaudeCandidate` when the user asks for the interactive normalizer for both windows.
- Use `-Mode Inspect` for a read-only measurement.
- Use `-Mode Apply` only when the user requested an immediate resize, and pass `-AllowClaudeCandidate` only when the user included Claude.
- Use `-Mode Restore` only when the user asks to restore the saved rectangles.
- Treat `gptpop` only as a target after its signed OpenAI executable, non-main window boundary, and Popout-compatible composer are verified.
- Treat `claudepop` only as a sizing label for one signed, visible Claude window candidate. It is not a registered Claude connection command and does not prove a retained Claude Popout or CogentSpec connection.
- Preserve foreground, Z-order, and topmost state. Report the requested and accepted physical-pixel dimensions separately, including `clamped_by_application`.
