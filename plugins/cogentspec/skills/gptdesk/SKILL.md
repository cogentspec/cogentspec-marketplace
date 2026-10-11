---
name: gptdesk
description: Open the current isolated CogentSpec project beside the current Codex or ChatGPT Desktop conversation in the compact Desktop UI layout. Use only when the user explicitly invokes $gptdesk or asks for the GPT Desktop split-screen command.
---

# Open CogentSpec beside the GPT Desktop conversation

Read `../cogentspec/SKILL.md` and follow its update, project-context, privacy, account, and connection requirements for **Connect the current AI project**, with these destination-specific changes only:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience desktop-ui` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `chatgptWorkspaceUrl` with `experience=desktop-ui`. Do not expose either private URL in commentary or logs.
3. Call `mcp__codex_app__open_in_codex` exactly once with `target: { type: "browser", url: workspaceUrl }` and `placement: "right"`. Omit `threadId` and `tabId`. This right-hand placement is the native two-column conversation/workspace split; do not accept a full-view browser tab as the intended GPTDesk layout. Treat `opened` or `queued` as accepted and do not retry.
4. On acceptance say: **CogentSpec is connected beside this GPT conversation.** If the native open is unavailable, return the independent `webWorkspaceUrl` once as `[Open CogentSpec workspace](<URL>)` and explain that the Desktop split view could not be opened automatically.

This command selects only the compact GPT Desktop UI route. It must not activate Popout layout, open the web destination as the primary route, automate the host sidebar, resize windows, or alter the shared project flow. Sidebar visibility remains a host-owned user control; never claim that opening the right-hand split also hid it. On Windows, if the user wants more work area, explain once that `Ctrl+Shift+S` toggles the host sidebar after the workspace opens. Never send that shortcut automatically: it is a toggle and can reopen a sidebar that is already collapsed.
