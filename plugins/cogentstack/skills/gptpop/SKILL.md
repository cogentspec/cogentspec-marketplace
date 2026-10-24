---
name: gptpop
description: Connect the current isolated project to its explicitly listening CogentSpec gptpop work area without opening a tab.
---

# gptpop Bridge command

Say **Connecting Bridge.**, then run `scripts/start-gptpop.ps1` once from the invoking project through the approved Windows-user execution tool. This command requires the CogentSpec package, its existing authenticated device installation and local execution access. A browser conversation alone cannot execute this command. For Qwen Web, run the command from an AI host with that local execution tool and keep the Qwen conversation beside the Qwen Web work area.

The user first selects **Initiate Bridge** in the intended CogentSpec tab. The helper resolves the isolated project, verifies the account/device and current worker, then sends a fresh challenge only to the registered **chatgpt / popout** listener. It preserves loaded work and the destination. A second tab is passive until the user explicitly confirms transfer. Never open, navigate, reload, focus, inspect or rearrange tabs/windows, use browser tools or a native open, or substitute another provider. Missing ownership is a connection failure, never permission to open a new destination.

Require `protocol: cogentspec-workspace-beacon-start-v1`, `status: connected`, `workspaceConnected: true`, `acknowledgementVerified: true`, `browserReused: true`, `browserOpened: false`, matching surface/experience and `browserHandoff: authenticated-workspace-reuse` before saying **Bridge connected.** A ready worker or historical acknowledgement is insufficient. On any failure show only the plain `userMessage` and stop. Do not retry, install, replace credentials or approve a device automatically. Keep all helper output, context, credentials and handoff material private.

For a required package update use the existing trusted update procedure for this host first, preserve its integrity and account/device approval gates, then resolve this helper beneath the refreshed package root. Do not run an installer or authorize anything merely because a listener is missing. Detailed diagnostics and project actions require a separate user request.

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
