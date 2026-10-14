---
name: gptpop
description: Compatibility alias for $gptsnap, the CogentSpec external-browser split-screen workspace.
---

# Compatibility alias for GPTSnap

`$gptpop` is the legacy alias for `$gptsnap`. Read `../gptsnap/SKILL.md` and follow its external-browser split-screen workflow exactly once. Do not run the generic Popout or GPTDesk launcher first. The alias shares the same isolated context, Bridge and destination as `$gptsnap`; it does not open a retained Popout.

## Explicit user-requested Desktop sizing

Window sizing is independent of connection. Only when the user explicitly asks to resize or normalize the main GPT/Codex Desktop or Claude Desktop window, invoke `../cogentstack/scripts/popout-window-normalizer.ps1` from the invoking workspace. The legacy filename does not make this a Popout target. Do not run the Bridge connection sequence unless the user also requested a connection.

- Default to `-Mode Widget -Width 900 -Height 600 -Target both -CompactOverride` when the user asks for the interactive normalizer for both desktop windows. In Widget mode, Compact override maintains the requested size while the widget remains open because an application can asynchronously reassert its minimum size after accepting an initial resize.
- Use `-Mode Inspect` for a read-only measurement.
- Use `-Mode Apply` only when the user requested an immediate resize.
- Use `-Mode Restore` only when the user asks to restore the saved rectangles.
- Restoring a formerly maximized window must not activate it: restore geometry, report `geometry_restored_maximize_deferred`, and let the user maximize it manually. The widget must not hide the host console.
- Target only the signed OpenAI process's exact main window with the expected desktop window class; never resize the retained GPTPop window.
- Target only one signed, visible, normal Claude Desktop application window, allowing its title to follow the active conversation; never describe it as a retained Claude Popout.
- Keep compact override explicit and report `applied_with_compact_override` only after the accepted physical frame matches the request. It may expose an application's narrow-layout limitations but must not inject code, change window styles, or send input.
- Preserve foreground, Z-order, and topmost state. Report the requested and accepted physical-pixel dimensions separately, including `clamped_by_application`.
