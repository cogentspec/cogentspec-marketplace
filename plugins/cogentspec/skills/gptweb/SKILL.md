---
name: gptweb
description: Open the current isolated CogentSpec project through the ordinary web-workspace flow for ChatGPT on the web. Use only when the user explicitly invokes $gptweb or asks for the GPT web command.
---

# Open the CogentSpec GPT web workspace

Read `../cogentspec/SKILL.md` and follow its update, project-context, privacy, account, and connection requirements for **Connect the current AI project**, with these destination-specific changes only:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience web` exactly once.
2. Require the normal ready contract and require `workspaceUrl` to be the private `webWorkspaceUrl` with the resolved `context`, `experience=web`, `open=web`, `nav`, and the private web handoff fragment. Do not expose either private URL in commentary or logs.
3. Do not apply the Popout-only `currentConversationConnected` gate, do not call the native Desktop browser-tab action, and do not return the generic recovery label. Return `workspaceUrl` exactly once as `[Open CogentSpec GPT web workspace](<URL>)`.
4. Say: **CogentSpec GPT web workspace is ready. Open the link to continue.**

This command selects only the ordinary GPT web destination. It must not activate Popout layout, request the compact Desktop UI route, resize windows, or alter the shared project flow.
