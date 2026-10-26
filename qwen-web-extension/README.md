# CogentSpec Qwen Web companion connector

This companion connects the Qwen browser conversation (including a Qwen.ai frame
inside a sidebar extension) to the authenticated CogentSpec Qwen Web work area. It does
not change or require a messaging API in the third-party Qwen sidebar extension.
It is separate from Qwen Local and the Popout lifecycle extension.

Load this directory as an unpacked extension in Chrome or Edge, then copy **this
companion's** extension ID from the browser Extensions page. With the newly
released CogentSpec package installed, run:

```powershell
.\register-native-host.ps1 -ExtensionId '<companion extension ID>' -PluginRoot '<installed CogentSpec plugin root>' -Browser Chrome
```

Registration is explicit, per Windows user and browser. It verifies the browser
signature and pins the installed helper's SHA-256. It does not read credentials,
install another extension, change policies or open tabs. After a package update,
run the same registration with `-Update` to refresh that pin. The third-party
extension ID `ophdppnnmjanpfpekojldpibobgegljk` is **not** the companion ID.

Open exactly one intended CogentSpec **Qwen Web** work area. Copy `$qwenweb` into the Qwen composer and send it. No Initiate Bridge listener is required. The companion observes only the exact command or its complete CogentSpec instruction envelope on a real Send/Enter action, waits for the conversation URL, derives its isolated task key and runs the fixed `start-qwenweb.ps1` launcher through native messaging. The launcher verifies the account/device, starts or reuses the local worker and returns a one-use authenticated Web handoff.

The companion requests confirmation in the intended work area before reloading it; cancel and save unfinished work first. It never selects between multiple work areas, navigates the Qwen conversation, or opens a replacement tab. Only the registered worker receives the private URL. After navigation it verifies the same context, consumed fragment, visible **Bridge connected** light and authorized project list before reporting connected. It reads no conversation replies. This requires refreshing the native registration with `-Update` after updating from the old listener-based connector.

Supported send controls are native form submit, unmodified Enter and clearly
identified Send buttons (`send-message-button`, `data-testid=send-button`,
submit buttons, English Send or Chinese 发送 labels). An unknown control fails
closed; use Enter in the composer. New-chat URL creation has an eight-second
budget. It never treats a login or settings page as a conversation.

The source includes isolated content-script, worker and Windows native framing
tests. Live compatibility with a particular Qwen sidebar version must still be
verified in the user's browser before calling that extension supported. No
third-party extension has been installed or altered by building these files.

For the prepared text command, use companion version 0.2.1 or later. Replace the unpacked companion source with the new download and reload it on the browser Extensions page. Its native helper, registration pin, account/device checks, work-area confirmation and acknowledgement checks are unchanged. No new Windows registration is needed when only these companion instruction files change.
