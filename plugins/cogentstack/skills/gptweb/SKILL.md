---
name: gptweb
description: Install or start the standalone CogentSpec GPTWeb helper for the exact Web request copied from its work area. Use only for $gptweb; other connector types use separate protocols.
---

# Connect CogentSpec GPTWeb

Read the official Git marketplace procedure at `../../../../web-bridge/v1/PROCEDURE.md` from the same repository revision as this file. Follow it for the copied request UUID and command `$gptweb`. It is self-contained: do not invoke shared connection skills, a Snap/Desk launcher, plugin installation, browser control or a listener-first flow.

When running from an installed local package, `scripts/start-gptweb.ps1 -RequestId <copied UUID>` is the equivalent verified bootstrap entry. It downloads the standalone Web helper from the official Git marketplace and waits for this exact tab's acknowledgement. Without a request UUID, ask the user to use the existing command-copy button in the intended Web work area; never discover or select a different tab.

Use the host's real Windows execution permission flow when required. A Linux executor cannot run this helper on the user's Windows computer. Report success only after the procedure's fresh acknowledgement checks pass.
