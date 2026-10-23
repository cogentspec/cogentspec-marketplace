---
name: gptsnap
description: Connect the isolated CogentSpec external-browser workspace with the installed GPTSnap command and its protected workspace acknowledgement.
---

# GPTSnap user command

Say **Connecting GPTSnap.**, run the installed command, then say **GPTSnap connected.** only when it returns `status: connected`. This is not a diagnostic request.

## Normal connection — no interface inspection

Use the current package's `scripts/gptsnap-client.mjs` and its exported `connectGptSnap` function in the approved host runtime. Run it once with the invoking workspace directory and one narrow opening callback:

```javascript
const result = await connectGptSnap({ cwd: invokingWorkspace, openWorkspace: url => gptPopTab.goto(url) });
```

Reuse the intended external browser and live-claim its CogentSpec tab using tab metadata only. If the destination is ambiguous, ask which tab. If no workspace tab exists, create one in the user-identified external browser. **Never use `open_in_codex` or an in-app browser pane.** No substitution with GPTDesk/Web, Popout or window-layout changes.

The installed client runs `scripts/start-gptsnap.ps1` once. The supervisor owns update/context/Bridge startup with `-Surface chatgpt -Experience split-screen`, validates the private `webWorkspaceUrl` handoff and emits a private `workspace_ready` event. The client opens that exact URL once; the supervisor then waits for the protected server acknowledgement. A ready worker, accepted URL open or redeemed grant alone cannot report connected.

**Do not inspect or debug the interface to confirm the connection.** No DOM/AX snapshots, selectors, page evaluation, LED inspection, project-list queries, Projects navigation, clicks, screenshots, console/network inspection or browser-state probes in a normal command. The workspace itself sends its acknowledgement; the command verifies it against the exact redeemed browser session, handoff, isolated context, active device lease and fresh worker presence. Never replace this acknowledgement with interface inspection, even on failure. Visual checks belong only to an explicitly requested diagnosis.

Capture protocol events privately. Do not print `workspaceUrl`, `browserNavigationCode`, fragments, helper output or stderr. No handoff transfers through files, clipboard, local servers or address-bar typing. Use the host-approved Windows-user execution scope; never bypass approval or integrity checks. Do not load the general-purpose skill, search files/history, repeat helpers, run tests or produce evidence reports during ordinary connection.

On `connected`, reply **GPTSnap connected.** On failure, show only the returned plain `userMessage` and stop; no automatic retry, reinstall or new approval. Never infer missing licences or request credentials. The helper's normal startup/acknowledgement budget is 50 seconds; a required update has a separate bounded allowance. A timer is not a guarantee of the entire conversational wait.

If browser control is unavailable, call the same client without `openWorkspace`. It prepares but does not consume the handoff; return its private URL once as **[Open CogentSpec GPT split-screen workspace](<URL>)** and report ready, not connected. Do not invent another opening method.

## Only if the command returns computer approval required

Keep the returned approval packet private. The helper validates `approvalProtocol: cogentspec-gptsnap-approval-v1` and the exact HTTPS cogentspec.com /activate destination, original context, future expiry and polling interval. Navigate once to its `approvalUrl`; the user approves computer access there. Never approve account/device replacement yourself or send the user to /install.

Poll `../cogentstack/scripts/connect-cogentstack.ps1 -Mode complete -BrowserApproval -ContextKey <same context> -Surface chatgpt -RequestTimeoutSeconds 6` no faster than `pollAfterSeconds` (at least 5 seconds), using the same request and stopping at expiry or any denial/error. On `authorized` with `browserAuthorizationCompleted: true`, use the client beneath `refreshedPluginPath` with `resumeApproval: { contextKey: sameContext }` and the same URL-opening callback. It resumes once without repeating update/context or starting another approval. Wait for the same protected acknowledgement before reporting success.

`$gptpop` is an alias for this exact flow.
