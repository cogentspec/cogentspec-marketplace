---
name: gptweb
description: Open the current isolated CogentSpec project through the ordinary web-workspace flow for ChatGPT on the web. Use only when the user explicitly invokes $gptweb or asks for the GPT web command.
---

# Open the CogentSpec GPT web workspace

Read `../cogentstack/SKILL.md` and follow its update, execution-permission, privacy, and account-error requirements. Do not run the generic connection flow. After any package refresh, use only the refreshed package's command-specific launcher:

1. Invoke `scripts/start-gptweb.ps1` exactly once from the invoking workspace. This is the sole GPTWeb entry point: it resolves the isolated context, starts or reuses Desktop Bridge with `-Experience web`, requests the web grant, and validates the complete handoff. Do not invoke `project-context.ps1`, `connect-cogentstack.ps1`, or `start-cogentstack-bridge.ps1` directly.
2. Require its normal ready contract and its single private `workspaceUrl`, which must contain the resolved `context`, `experience=web`, `open=web`, `nav`, and `#desktop-web=` handoff. Treat `invalid_workspace_handoff` as a hard failure. Never construct, repair, or return a URL yourself, and never return a legacy `#desktop=` authorization route. Do not expose the private URL in commentary or logs.
3. Do not apply the Popout-only `currentConversationConnected` gate, do not call the native Desktop browser-tab action, and do not return the generic recovery label. Return `workspaceUrl` exactly once as `[Open CogentSpec GPT web workspace](<URL>)`.
4. Say: **CogentSpec GPT web workspace is ready. Open the link to continue.**

This command selects only the ordinary GPT web destination. It must not activate Popout layout, request the compact Desktop UI route, resize windows, or alter the shared project flow.
