---
name: gptpop
description: Open the current isolated CogentSpec project in its ChatGPT Popout work-area flow. Use only when the user explicitly invokes $gptpop or asks for the GPT Popout command.
---

# Open the CogentSpec GPT Popout work area

Read `../cogentstack/SKILL.md` and follow its update, project-context, privacy, account, and connection requirements for **Connect the current AI project**, with these destination-specific changes only:

1. Invoke `../cogentstack/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience popout` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `webWorkspaceUrl` with `experience=popout`. Do not expose either private URL in commentary or logs.
3. Call `mcp__codex_app__open_in_codex` exactly once with `target: { type: "browser", url: workspaceUrl }`. Omit `threadId`, `tabId`, and `placement`. Treat `opened` or `queued` as accepted and do not retry.
4. On acceptance say: **CogentSpec GPT Popout work area is connected.** If the native open is unavailable, return `workspaceUrl` once as `[Open CogentSpec GPT Popout work area](<URL>)`.

This command selects only the ChatGPT Popout destination. It must not switch to the compact Desktop UI layout or the ordinary web destination, resize windows, or alter the shared project flow.
