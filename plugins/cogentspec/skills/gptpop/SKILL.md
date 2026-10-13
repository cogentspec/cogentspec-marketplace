---
name: gptpop
description: Open the current isolated CogentSpec project in its ChatGPT Popout work-area flow, or open the user-requested Popout Window Normalizer. Use when the user explicitly invokes $gptpop, asks for the GPT Popout command, or explicitly asks to resize or normalize GPTPop and the signed Claude window candidate.
---

# Open the CogentSpec GPT Popout work area

Read `../cogentspec/SKILL.md` and follow its update, project-context, privacy, account, and connection requirements for **Connect the current AI project**, with these destination-specific changes only:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience popout` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `webWorkspaceUrl` with `experience=popout`. Do not expose either private URL in commentary or logs.
3. Call `mcp__codex_app__open_in_codex` exactly once with `target: { type: "browser", url: workspaceUrl }`. Omit `threadId`, `tabId`, and `placement`. Treat `opened` or `queued` as accepted and do not retry.
4. On acceptance say: **CogentSpec GPT Popout work area is connected.** If the native open is unavailable, return `workspaceUrl` once as `[Open CogentSpec GPT Popout work area](<URL>)`.

This command selects only the ChatGPT Popout destination. A normal `$gptpop` connection must not switch to the compact Desktop UI layout or the ordinary web destination, resize windows, or alter the shared project flow.

## Explicit user-requested Popout sizing

Window sizing is independent of connection. Only when the user explicitly asks to resize or normalize GPTPop or the Claude window, invoke `../cogentspec/scripts/popout-window-normalizer.ps1` from the invoking workspace. Do not run the Bridge connection sequence unless the user also requested a connection.

- Default to `-Mode Widget -Width 900 -Height 600 -Target both -AllowClaudeCandidate` when the user asks for the interactive normalizer for both windows.
- Use `-Mode Inspect` for a read-only measurement.
- Use `-Mode Apply` only when the user requested an immediate resize, and pass `-AllowClaudeCandidate` only when the user included Claude.
- Use `-Mode Restore` only when the user asks to restore the saved rectangles.
- Treat `gptpop` only as a target after its signed OpenAI executable, non-main window boundary, and Popout-compatible composer are verified.
- Treat `claudepop` only as a sizing label for one signed, visible Claude window candidate. It is not a registered Claude connection command and does not prove a retained Claude Popout or CogentSpec connection.
- Preserve foreground, Z-order, and topmost state. Report the requested and accepted physical-pixel dimensions separately, including `clamped_by_application`.
