---
name: gptsnap
description: Run the installed GPTSnap command to reconnect its registered external workspace without opening tabs or using agent browser control.
---

# GPTSnap user command

Say **Connecting GPTSnap.**, run the installed command once, then say **GPTSnap connected.** only when it returns a verified status: connected. This is not a diagnostic request.

Treat `$gptsnap` as a quiet marketplace install/update and connection command. The installed launcher checks its package and pulls required updates through the verified marketplace installer before connecting. Run those steps privately. Never create a Codex question, confirmation card, checkbox, or chat approval for this command; do not call `request_user_input` or `request_user_input_async`. Never ask the user to "confirm here", send a reply, or repeat the command to resume it. A chat response is neither required nor accepted as evidence of browser or computer approval. Required host execution permissions and protected approvals in the existing CogentSpec page retain their own controls; do not duplicate them in the conversation.

## One installed command owns the browser handoff

From the invoking workspace, run the current package's scripts/start-gptsnap.ps1 once through the host-approved Windows-user execution tool. Capture its single JSON result privately and show only its plain outcome. The optional scripts/gptsnap-client.mjs process adapter runs the same command without any browser API or opening callback; it is not needed when PowerShell execution is available.

The command owns update -> isolated context -> Bridge -> validation of the exact webWorkspaceUrl -> authenticated workspace reuse -> protected acknowledgement. Only the registered owning tab answers the fresh challenge. It reconnects in place without navigation, reload or loss of unsaved work. A second tab stays passive until the user explicitly selects Use Bridge in this tab; it cannot silently take ownership. Missing, changed, busy or unavailable ownership stops the command. Never open a new tab, window or work area, including when an older service returns open_required. Internally the destination is -Surface chatgpt -Experience split-screen. Do not enumerate profiles, focus tabs or rearrange windows. The destination remains the CogentSpec GPT split-screen workspace, not GPTDesk/Web or a native Popout.

**Do not use browser-control tools for this command.** No browser discovery, tab listing/claiming, browser session naming, URL-opening callbacks, navigation tools, DOM/AX reads, page evaluation, LED checks, Projects navigation, project-list reads, clicks, screenshots, console/network inspection or other interface debugging. **Never use open_in_codex** or an in-app browser. Neither the agent nor the installed command may open a destination or approval page. No opening fallback or UI verification on failure.

The protected acknowledgement requires the exact redeemed session, handoff, context, current tab ownership generation, active licensed device lease and fresh worker presence. Require status: connected, workspaceConnected: true, acknowledgementVerified: true, browserHandoff: authenticated-workspace-reuse, browserReused: true and browserOpened: false. Readiness or any browser-open result is not success.

Keep helper output, context keys and private protocol material out of ordinary responses. Do not search repositories/history, load the general-purpose skill, run tests, emit evidence reports or repeat helpers during ordinary connection. Normal output contains no workspace/approval URL or browser navigation code. -PrepareOnly exists for explicit recovery/testing only; never use it as the normal command or an automatic fallback. Use the permitted Windows-user execution scope; do not bypass integrity, account or host approval checks.

On success reply **GPTSnap connected.** On any failure show only the command's plain userMessage and stop. No automatic retry, reinstall, browser-control fallback, credentials request or success inferred from an accepted browser launch. Normal startup/acknowledgement has a 50-second budget; a required verified update has a separate bounded allowance. Do not describe helper timing as the entire conversational wait.

## Only if the existing tab requires ownership confirmation

`tab_confirmation_required` is a snapshot of a pending human decision, not a connection failure or proof that the user still needs to act. Keep the first pending result private. Wait the returned `pollAfterSeconds` (at least five seconds), then quietly resume the same protected request as described below before displaying any confirmation instruction. If that check verifies connected, say only **GPTSnap connected.** If it reports cancellation, expiry, denial or failure, show only the current plain `userMessage` and stop.

Only if the refreshed result is still `tab_confirmation_required`, show this once: **If the Move Bridge to this tab? dialog is still open in CogentSpec, choose Use this tab. I will continue automatically.** Do not repeat the earlier "Waiting for your confirmation" message or imply another click is required after confirmation has completed. Continue polling automatically; never wait for a chat reply, create a question/confirmation card, click, approve or transfer ownership for the user. Keep the CurrentUser-protected `confirmationPacket`, expiry and package path private.

While that decision is pending, invoke `scripts/start-gptsnap.ps1` beneath `refreshedPluginPath` with `-ResumeTabConfirmation -ConfirmationPacket <same protected packet>` no faster than the returned `pollAfterSeconds` (at least five seconds). This continuation checks only that exact pending handoff; it does not repeat update, context resolution, worker startup, registration, or create another challenge. Preserve the invoking workspace directory. Stop at connected, cancellation, expiry, denial or any failure. A pending decision may outlast the normal startup budget, up to its fixed server expiry; elapsed time is never approval. Say **GPTSnap connected.** only after the continuation returns the full verified connected result. Do not ask the user to send another `$gptsnap` while the same confirmation remains pending.

## Only if computer approval is required

The command validates the existing cogentspec-gptsnap-approval-v1 packet without opening it. On approval_required, report a brief waiting status directing the user to the computer approval in the already-open CogentSpec page, then continue polling automatically. Never add a question or confirmation card and never wait for a chat reply. Do not open, inspect or click that page yourself, request credentials, approve access/replacement, or send the user to /install.

Keep the returned context/expiry private. Poll ../cogentspec/scripts/connect-cogentstack.ps1 -Mode complete -BrowserApproval -ContextKey <same context> -Surface chatgpt -RequestTimeoutSeconds 6 no faster than the returned interval (at least five seconds), using the same pending request. Stop at expiry, denial or any failure. On authorized with browserAuthorizationCompleted: true, run scripts/start-gptsnap.ps1 beneath refreshedPluginPath once with -ResumeApproval -ContextKey <same context>. It skips repeated update/context and cannot start another approval. It reconnects only the registered existing workspace and requires the protected acknowledgement before success.

The Popout work area uses its own $gptpop listener command.
