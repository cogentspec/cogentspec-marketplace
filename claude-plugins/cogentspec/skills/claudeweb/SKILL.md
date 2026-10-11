---
name: claudeweb
description: Connect the current isolated Claude project through the ordinary CogentSpec web workspace. Use only when the user explicitly invokes $claudeweb or asks for the Claude web command.
---

# Open the CogentSpec Claude web workspace

Read `../cogentspec/SKILL.md` and follow its project-context, privacy, account, and connection requirements for **Connect this Claude project**, with these destination-specific changes only:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface claude-desktop -Experience web` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `webWorkspaceUrl` with `experience=web`. Do not expose either private URL in commentary or logs.
3. Return that URL exactly once as `[Open this task’s CogentSpec workspace in web](<URL>)`. Do not return the Claude-labelled Desktop link.
4. Say: **CogentSpec’s Claude web workspace is ready. Open the link to continue.**

This command selects only the ordinary web destination for the current Claude project. It must not call browser control, create or select a tab, resize or join the Claude window, activate ChatGPT Popout behavior, or alter the shared project flow.
