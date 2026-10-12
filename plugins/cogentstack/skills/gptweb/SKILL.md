---
name: gptweb
description: Open the current isolated CogentSpec project through the ordinary web-workspace flow for ChatGPT on the web. Use only when the user explicitly invokes $gptweb or asks for the GPT web command.
---

# Open the CogentSpec GPT web workspace

Read `../cogentstack/SKILL.md` and follow its update, execution-permission, privacy, and account-error requirements. Do not run the generic connection flow. After any package refresh, use only the refreshed package's command-specific launcher:

1. Invoke `scripts/start-gptweb.ps1` exactly once from the invoking workspace. This is the sole GPTWeb entry point: it resolves the isolated context, starts or reuses Desktop Bridge with `-Experience web`, requests the web grant, and validates the complete handoff. Do not invoke `project-context.ps1`, `connect-cogentstack.ps1`, or `start-cogentstack-bridge.ps1` directly.
2. Require its normal ready contract and its single private `workspaceUrl`, which must contain the resolved `context`, `experience=web`, `open=web`, `nav`, and `#desktop-web=` handoff. Treat `invalid_workspace_handoff` as a hard failure. Never construct, repair, or return a URL yourself, and never return a legacy `#desktop=` authorization route. Do not expose the private URL in commentary or logs.
3. Deliver the verified handoff to the browser. When browser control is available, inspect the user-selected tab before navigation. If it is on `https://cogentspec.app/stack` with `experience=web`, navigate that same tab to the returned `workspaceUrl` once. Otherwise open that URL once in the browser identified by the user or current browser context. Preserve the entire returned URL; the short setup URL does not establish a connection. Do not call the native Desktop browser-tab action or apply the Popout-only `currentConversationConnected` gate.
4. Verify the resulting page before reporting connection: its context must match the returned context, its one-use fragment must be consumed, and the visible LED must report **Bridge connected**. Check **My projects** loads without an authorization or missing-context error; an empty authorized library is valid. Report **CogentSpec GPT web workspace is connected. Continue beside this conversation.** only after these checks. If delivery succeeds but verification fails, report the observed failure and stop; do not generate another handoff or claim success from Bridge readiness alone.
5. If browser control is unavailable or navigation was not accepted, return `workspaceUrl` exactly once as `[Open CogentSpec GPT web workspace](<URL>)` and say: **CogentSpec GPT web workspace is ready. Open the link to continue.** Explain that the existing page stays disconnected until this link is opened. A returned link is a fallback, not automatic connection. Do not return a consumed handoff.

This command selects only the ordinary GPT web destination. It must not activate Popout layout, request the compact Desktop UI route, resize windows, or alter the shared project flow.
