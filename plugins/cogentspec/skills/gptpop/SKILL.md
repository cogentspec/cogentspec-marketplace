---
name: gptpop
description: Open the isolated CogentSpec workspace beside the main desktop chat window for Windows split screen using $gptpop.
---

# Open the CogentSpec GPT split-screen workspace

The command name `$gptpop` is retained for compatibility. It now uses the main desktop chat window beside a CogentSpec browser window in Windows split screen. Read `../cogentspec/SKILL.md` for the update, isolated context, privacy and account steps, then follow this flow instead of its generic Popout connection steps:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience split-screen` exactly once.
2. Require `status: ready`, the matching isolated context, `presenceVerified: true`, `accountState: signed_in`, `projectDataConnection: authenticated_desktop_bridge`, `mcpState: not_required`, `defaultDirectoryReady: true`, and `browserOpened: false`.
3. Validate `workspaceUrl` equals `webWorkspaceUrl`, has origin `https://cogentspec.app` and path `/stack`, and contains the resolved context, `surface=chatgpt`, `experience=split-screen`, `open=web`, a fresh nav and complete `#desktop-web=cgw_...` handoff. Keep private links out of commentary, logs, clipboard and files.
4. Open that exact link once using the browser-opening action. In Codex use `mcp__codex_app__open_in_codex` with `target: { type: "browser", url: workspaceUrl }`, omitting thread, tab and placement. Accept `opened` or `queued` without retry. If opening is unavailable, return the link once as `[Open CogentSpec GPT split-screen workspace](<URL>)`.
5. Report Bridge readiness and opening separately. Say the split-screen workspace was opened or queued. Only claim a visibly connected page after observing its context-matched green LED. Popout fields including `currentConversationConnected: false` do not apply here; do not report them as a failed main desktop conversation or inspect, open, pin or hide a Popout.

Help explains launching ChatGPT Desktop, resizing it to fit, and **Win + Left/Right arrow** to snap each window. Physical snapping is user-controlled; Bridge readiness and an accepted browser open do not prove the split is arranged. Keep `$gptdesk` and `$gptweb` as separate destinations.

## Explicit user-requested Popout sizing

Window sizing is independent of connection. Only when the user explicitly asks to resize or normalize GPTPop or the Claude window, invoke `../cogentspec/scripts/popout-window-normalizer.ps1` from the invoking workspace. Do not run the Bridge connection sequence unless the user also requested a connection.

- Default to `-Mode Widget -Width 900 -Height 600 -Target both -AllowClaudeCandidate` when the user asks for the interactive normalizer for both windows.
- Use `-Mode Inspect` for a read-only measurement.
- Use `-Mode Apply` only when the user requested an immediate resize, and pass `-AllowClaudeCandidate` only when the user included Claude.
- Use `-Mode Restore` only when the user asks to restore the saved rectangles.
- Treat `gptpop` only as a target after its signed OpenAI executable, non-main window boundary, and Popout-compatible composer are verified.
- Treat `claudepop` only as a sizing label for one signed, visible Claude window candidate. It is not a registered Claude connection command and does not prove a retained Claude Popout or CogentSpec connection.
- Preserve foreground, Z-order, and topmost state. Report the requested and accepted physical-pixel dimensions separately, including `clamped_by_application`.
