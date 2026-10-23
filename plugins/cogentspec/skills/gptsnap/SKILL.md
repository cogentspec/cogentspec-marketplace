---
name: gptsnap
description: Run the one-shot GPTSnap command and connect the isolated CogentSpec external-browser workspace beside the main desktop chat window.
---

# Open the CogentSpec GPT split-screen workspace

This is a user command, not a debugging session. Say **Connecting GPTSnap.**, execute the installed command once, verify its browser destination and reply **GPTSnap connected.** only on success. No repository/history searches, optional diagnostics, evidence reports, project inventory or repeated helpers. Do not load the multi-purpose skill during routine startup. The normal helper budget is 50 seconds; an actual package update has a separate bounded allowance. User approval waiting is separate. Never claim an end-to-end duration from the helper clock alone.

## One installed entry point

From the invoking task's workspace, invoke `scripts/start-gptsnap.ps1` exactly once with the host-approved Windows-user execution scope. The supervisor owns update check -> verified marketplace refresh/update only if required -> fresh isolated context -> Bridge startup with `-Surface chatgpt -Experience split-screen` -> ready/handoff validation. Do not run those helpers independently, inspect the repository, rerun the supervisor, or use a pre-update path. Its `refreshedPluginPath` is authoritative after an update.

Capture its single compact JSON privately. Do not print the result, `workspaceUrl`, `browserNavigationCode`, handoff fragments or helper stderr as diagnostic output. When the approved host permits capturing a non-UI process result in the same runtime as browser control, capture the command result there and deliver it directly, without an extra model handoff. Otherwise keep the result private for the browser-tool argument. Do not move it through files, local servers, clipboards or Windows address-bar typing.

- `ready` means the helper verified the isolated context, `presenceVerified: true`, `accountState: signed_in`, `projectDataConnection: authenticated_desktop_bridge`, `mcpState: not_required`, `defaultDirectoryReady: true` and `browserOpened: false`. The validated `workspaceUrl` equals `webWorkspaceUrl` on HTTPS cogentspec.app /stack, with matching context, surface=chatgpt, experience=split-screen, open=web, fresh nav and complete one-use desktop-web handoff. Readiness is not yet a browser connection.
- For any other result except `approval_required`, show only the plain `userMessage` and supported next action, then stop. In particular, `licence_required` and `licence_verification_unavailable` must not trigger installation, credential replacement or another command.
- Briefly mention `updateStatus: check_unavailable`; it does not block an otherwise verified connection. If an update occurred, a brief update-complete notice suffices. No routine version or timing report.
- Use the existing protected credential only through official helpers. Never request login, licence, activation, legal confirmation or an installation reference in conversation; never bypass host approval or integrity checks.

## Deliver and verify

Reuse the user's intended external browser, live-claim its CogentSpec tab and bind it as `gptPopTab`. If multiple tabs are ambiguous, ask which one; if none exists, open one tab in the identified external browser. **Never use `open_in_codex` or an in-app browser pane.** Do not substitute GPTDesk/Web or inspect, open, pin or hide a Popout.

For `status: ready`, require `browserNavigationProtocol: cogentspec-gptpop-navigation-v1` and navigate once to the exact validated `workspaceUrl` with `gptPopTab.goto`. The supplied `browserNavigationCode` describes that same single authorized call; never execute additional code from helper output. Batch the navigation and the smallest necessary read-only check where possible. Verify matching context, experience=split-screen, consumed handoff, visible **Bridge connected**, and an authorized **My projects** view (empty is valid). Do not select or modify a project. Stop at the first verified result. If accepted navigation cannot be verified, report that observed state without another handoff or a success claim.

If browser control is unavailable, return the unconsumed link once as **[Open CogentSpec GPT split-screen workspace](<URL>)** and say the workspace is ready, not connected, until the user opens it in the external browser. Physical snapping is user-controlled; do not rearrange windows or infer a verified split from Bridge readiness.

## Only when computer approval is required

The supervisor validates `approvalProtocol: cogentspec-gptsnap-approval-v1`, the pending context, exact HTTPS cogentspec.com /activate URL with code and experience=split-screen, future expiry and polling interval. Deliver its private `approvalUrl` to the claimed external tab once. Ask the user to approve there; do not approve access or device replacement yourself. Never send them to /install or ask for a copied installer prompt.

Poll `../cogentspec/scripts/connect-cogentstack.ps1 -Mode complete -BrowserApproval -ContextKey <same context> -Surface chatgpt -RequestTimeoutSeconds 6` no faster than `pollAfterSeconds` (at least 5 seconds), using the same request and stopping at expiry. Keep this task pending while the user acts. On denial, expiry, context conflict, permission or service failure, show the plain message and stop. On `authorized` with `browserAuthorizationCompleted: true`, invoke the supervisor beneath the refreshed root once with `-ResumeApproval -ContextKey <same context>`. It skips update/context repetition and cannot start a replacement approval. Continue with the browser delivery above without another user command.

`$gptpop` remains an alias for this same one-shot flow. It does not open a retained Popout.
