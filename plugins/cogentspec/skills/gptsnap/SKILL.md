---
name: gptsnap
description: Open the isolated CogentSpec workspace beside the main desktop chat window for Windows split screen using $gptsnap.
---

# Open the CogentSpec GPT split-screen workspace

`$gptsnap` is the canonical command; `$gptpop` remains a compatibility alias. It uses the main desktop chat window beside a CogentSpec browser window in Windows split screen. Read `../cogentspec/SKILL.md` for the update, isolated context, privacy and account steps, then follow this flow instead of its generic Popout connection steps:

1. Invoke `../cogentspec/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt -Experience split-screen` exactly once.
2. Require `status: ready`, the matching isolated context, `presenceVerified: true`, `accountState: signed_in`, `projectDataConnection: authenticated_desktop_bridge`, `mcpState: not_required`, `defaultDirectoryReady: true`, and `browserOpened: false`.
3. Validate `workspaceUrl` equals `webWorkspaceUrl`, has origin `https://cogentspec.app` and path `/stack`, and contains the resolved context, `surface=chatgpt`, `experience=split-screen`, `open=web`, a fresh nav and complete `#desktop-web=cgw_...` handoff. Keep private links out of commentary, logs, clipboard and files.
4. Use the external browser window the user has snapped beside the main desktop chat. Inspect and live-claim its intended CogentSpec tab, then bind it as `gptPopTab`. Require `browserNavigationProtocol: cogentspec-gptpop-navigation-v1` and execute the returned `browserNavigationCode` verbatim once as a browser-tool argument. It is the JSON-quoted `await gptPopTab.goto(...);` call for the validated handoff. This authorised tool argument may contain the one-use link; never echo it as diagnostic output or move it through a clipboard, local server, temporary file or Windows address-bar typing. If multiple external CogentSpec tabs make the target ambiguous, ask which one. If no external workspace exists, open one tab in the user-identified external browser. **Never use `open_in_codex` or an in-app browser pane for `$gptsnap`.** Do not substitute `$gptdesk` or `$gptweb`.
5. Verify that same external tab has the returned project context, `experience=split-screen`, a consumed handoff fragment, and a visible **Bridge connected** indicator. Check **My projects** loads without an authorization or missing-context error; an empty authorized library is valid. Only then say **CogentSpec GPT split-screen workspace is connected in your external browser.** If navigation is accepted but verification fails, report the observed state and stop without generating another handoff. Popout fields including `currentConversationConnected: false` do not apply here; do not inspect, open, pin or hide a Popout.
6. If browser control is unavailable, return the unconsumed `workspaceUrl` once as `[Open CogentSpec GPT split-screen workspace](<URL>)` and explicitly ask the user to open it in the right-hand external browser. Report only Bridge readiness until that page is verified. Never fall back to an embedded browser.

Help explains launching ChatGPT Desktop, resizing it to fit, and **Win + Left/Right arrow** to snap each window. Physical snapping is user-controlled; Bridge readiness and an accepted browser open do not prove the split is arranged. Keep `$gptdesk` and `$gptweb` as separate destinations.
