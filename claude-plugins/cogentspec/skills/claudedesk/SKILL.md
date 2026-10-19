---
name: claudedesk
description: Connect the current isolated Claude Code Desktop project to its Claude-labelled CogentSpec workspace. Use only when the user explicitly invokes $claudedesk or asks for the Claude Desktop command.
---

# Open the CogentSpec Claude Desktop workspace

If a helper returns `licence_required`, show its plain `userMessage` and stop: this account needs an active CogentSpec licence (an enabled, eligible owner licence counts). Do not start installation, reconnect, computer approval, another command, or a workspace open. Preserve the saved credential. If it returns `licence_verification_unavailable`, report that access could not be checked; do not claim the licence is missing or start approval. A missing credential alone does not prove a missing licence; retain the documented first-time account/device authorization flow only for genuinely unidentified or revoked connections.

Read `../cogentspec/SKILL.md` and follow its project-context, privacy, account, and connection requirements for **Connect this Claude project**, with these destination-specific changes only:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface claude-desktop -Experience desktop` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `chatgptWorkspaceUrl` with `experience=desktop`. Do not expose either private URL in commentary or logs.
3. Return that URL exactly once as `[Open this task’s CogentSpec workspace in Claude](<URL>)`. Do not return the independent web-workspace link unless this destination cannot be prepared.
4. Say: **CogentSpec’s Claude Desktop workspace is ready. Open the link to continue.**

This command selects only the Claude-labelled Desktop destination. It must not call browser control, create or select a tab, resize or join the Claude window, activate ChatGPT Popout behavior, or alter the shared project flow.
