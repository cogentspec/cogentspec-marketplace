---
name: gptdesk
description: Open the current isolated CogentSpec project beside the current Codex or ChatGPT Desktop conversation in the compact Desktop UI layout. Use only when the user explicitly invokes $gptdesk or asks for the GPT Desktop split-screen command.
---

# Open CogentSpec beside the GPT Desktop conversation

Read `../cogentstack/SKILL.md` and follow its update, project-context, privacy, account, and connection requirements for **Connect the current AI project**, with these destination-specific changes only:

1. Invoke `../cogentstack/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience desktop-ui` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `chatgptWorkspaceUrl` with `experience=desktop-ui`. Do not expose either private URL in commentary or logs.
3. On Windows, run `py -3 ../cogentstack/scripts/ensure-codex-sidebar-hidden.py --timeout-ms 3000` exactly once. Read its one-line JSON. Treat `hidden` or `already_hidden` as success. The helper inspects the explicit `Hide sidebar` or `Show sidebar` accessibility control. It sends `Ctrl+Shift+S` exactly once only when one foreground Codex window explicitly reports `Hide sidebar`, then verifies that the state changed to `Show sidebar`; it must never send the toggle when the sidebar is already hidden or the state is unclear. If Python is unavailable or the helper returns `unavailable`, `ambiguous`, or `failed`, continue opening the workspace and say once that the Codex sidebar could not be closed automatically.
4. Call `mcp__codex_app__open_in_codex` exactly once with `target: { type: "browser", url: workspaceUrl }` and `placement: "right"`. Omit `threadId` and `tabId`. This right-hand placement is the native two-column conversation/workspace split; do not accept a full-view browser tab as the intended GPTDesk layout. Treat `opened` or `queued` as accepted and do not retry.
5. On acceptance say: **CogentSpec is connected beside this GPT conversation.** If the native open is unavailable, return the independent `webWorkspaceUrl` once as `[Open CogentSpec workspace](<URL>)` and explain that the Desktop split view could not be opened automatically.

This command selects only the compact GPT Desktop UI route. It must not activate Popout layout, open the web destination as the primary route, resize windows, or alter the shared project flow. On Windows, close the host sidebar only through the state-aware Python helper above. Never send `Ctrl+Shift+S` without first proving the sidebar is open, because the same shortcut can reopen a sidebar that is already collapsed.
