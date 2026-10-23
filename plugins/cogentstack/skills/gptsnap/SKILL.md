---
name: gptsnap
description: Run the installed GPTSnap command, which opens its external browser workspace and confirms the protected connection without agent browser control.
---

# GPTSnap user command

Say **Connecting GPTSnap.**, run the installed command once, then say **GPTSnap connected.** only when it returns a verified status: connected. This is not a diagnostic request.

## One installed command owns the browser handoff

From the invoking workspace, run the current package's scripts/start-gptsnap.ps1 once through the host-approved Windows-user execution tool. Capture its single JSON result privately and show only its plain outcome. The optional scripts/gptsnap-client.mjs process adapter runs the same command without any browser API or opening callback; it is not needed when PowerShell execution is available.

The command owns update -> isolated context -> Bridge -> validation of the exact webWorkspaceUrl -> authenticated workspace reuse -> protected acknowledgement. An existing matching workspace answers a fresh challenge and reconnects in place without navigation, reload or loss of unsaved work. Only a verified absence of a responding workspace permits one Windows-default-browser handoff. Unavailable or ambiguous reuse checks stop without opening another work area. Internally the destination is -Surface chatgpt -Experience split-screen. Do not enumerate profiles. No physical snapping, tab focusing or window rearrangement is performed. The destination remains the CogentSpec GPT split-screen workspace, not GPTDesk/Web or a native Popout.

**Do not use browser-control tools for this command.** No browser discovery, tab listing/claiming, browser session naming, URL-opening callbacks, navigation tools, DOM/AX reads, page evaluation, LED checks, Projects navigation, project-list reads, clicks, screenshots, console/network inspection or other interface debugging. **Never use open_in_codex** or an in-app browser. The installed command opens the validated destination itself, including a required approval page. Never perform a second browser handoff or use UI verification on failure.

The protected acknowledgement requires the exact redeemed session, handoff, context, active licensed device lease and fresh worker presence. browserOpened: true or a ready worker alone cannot mean connected. Require status: connected, workspaceConnected: true and acknowledgementVerified: true. A reused work area returns browserHandoff: authenticated-workspace-reuse, browserReused: true, browserOpened: false; a newly opened work area returns browserHandoff: windows-default-browser and browserOpened: true.

Keep helper output, context keys and private protocol material out of ordinary responses. Do not search repositories/history, load the general-purpose skill, run tests, emit evidence reports or repeat helpers during ordinary connection. Normal output contains no workspace/approval URL or browser navigation code. -PrepareOnly exists for explicit recovery/testing only; never use it as the normal command or an automatic fallback. Use the permitted Windows-user execution scope; do not bypass integrity, account or host approval checks.

On success reply **GPTSnap connected.** On any failure show only the command's plain userMessage and stop. No automatic retry, reinstall, browser-control fallback, credentials request or success inferred from an accepted browser launch. Normal startup/acknowledgement has a 50-second budget; a required verified update has a separate bounded allowance. Do not describe helper timing as the entire conversational wait.

## Only if computer approval is required

The command validates the existing cogentspec-gptsnap-approval-v1 packet and opens its official HTTPS approval destination once through Windows. On approval_required, ask the user to approve this computer in the already-open CogentSpec page. Do not open, inspect or click that page yourself, request credentials, approve access/replacement, or send the user to /install.

Keep the returned context/expiry private. Poll ../cogentspec/scripts/connect-cogentstack.ps1 -Mode complete -BrowserApproval -ContextKey <same context> -Surface chatgpt -RequestTimeoutSeconds 6 no faster than the returned interval (at least five seconds), using the same pending request. Stop at expiry, denial or any failure. On authorized with browserAuthorizationCompleted: true, run scripts/start-gptsnap.ps1 beneath refreshedPluginPath once with -ResumeApproval -ContextKey <same context>. It skips repeated update/context and cannot start another approval. It opens the workspace itself and must return the same protected acknowledgement before success.

$gptpop is an alias for this flow.
