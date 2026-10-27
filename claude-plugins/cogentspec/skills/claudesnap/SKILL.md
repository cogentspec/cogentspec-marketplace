---
name: claudesnap
description: Connect the current isolated project to its explicitly listening CogentSpec claudesnap work area without opening a tab.
---

# claudesnap Bridge command

Say **Connecting Bridge.**, then run `scripts/start-claudesnap.ps1` once from the invoking project through the approved Windows-user execution tool. This command requires the CogentSpec package, its existing authenticated device installation and local execution access. A browser conversation alone cannot execute this command. For Qwen Web, run the command from an AI host with that local execution tool and keep the Qwen conversation beside the Qwen Web work area.

The user first selects **Initiate Bridge** in the intended CogentSpec tab. The helper resolves the isolated project, verifies the account/device and current worker, then sends a fresh challenge only to the registered **claude-desktop / split-screen** listener. It preserves loaded work and the destination. A second tab is passive until the user explicitly confirms transfer. Never open, navigate, reload, focus, inspect or rearrange tabs/windows, use browser tools or a native open, or substitute another provider. Missing ownership is a connection failure, never permission to open a new destination.

Keep intermediate confirmation and acknowledgement progress private while the launcher is running. This launcher waits for tab confirmation internally and returns the current connection outcome; wait for its final JSON result before reporting. Do not print a waiting/confirmation instruction from an earlier status, the initial Initiate Bridge step or a previous command. A verified connected result needs only **Bridge connected.**, even if confirmation happened earlier during the command. Do not start another launcher, invent GPTSnap continuation arguments, inspect the browser or ask for another confirmation to refresh the status. If the final result is a failure, follow the current plain failure message below.

Require `protocol: cogentspec-workspace-beacon-start-v1`, `status: connected`, `workspaceConnected: true`, `acknowledgementVerified: true`, `browserReused: true`, `browserOpened: false`, matching surface/experience and `browserHandoff: authenticated-workspace-reuse` before saying **Bridge connected.** A ready worker or historical acknowledgement is insufficient. On any failure show only the plain `userMessage` and stop. Do not retry, install, replace credentials or approve a device automatically. Keep all helper output, context, credentials and handoff material private.

For a required package update use the existing trusted update procedure for this host first, preserve its integrity and account/device approval gates, then resolve this helper beneath the refreshed package root. Do not run an installer or authorize anything merely because a listener is missing. Detailed diagnostics and project actions require a separate user request.
