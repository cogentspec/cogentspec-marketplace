# CogentSpec Qwen Web companion connector

This companion connects the Qwen browser conversation (including a Qwen.ai frame
inside a sidebar extension) to the existing CogentSpec Qwen Web listener. It does
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

In the existing CogentSpec **Qwen Web** work area, select **Initiate Bridge** and
wait for the orange listening light. Copy `$qwenweb` into the Qwen composer and
send it. The companion observes only the exact command on a real Send/Enter
action. It lets Qwen create its conversation URL, derives a private task key from
that URL, and invokes the fixed Qwen Web helper through native messaging. It
does not read conversation replies or other messages. The work area's green
light requires the live account/device/owner acknowledgement; the companion
never opens, reloads, navigates or focuses any tab or window.

Supported send controls are native form submit, unmodified Enter and clearly
identified Send buttons (`send-message-button`, `data-testid=send-button`,
submit buttons, English Send or Chinese 发送 labels). An unknown control fails
closed; use Enter in the composer. New-chat URL creation has an eight-second
budget. It never treats a login or settings page as a conversation.

The source includes isolated content-script, worker and Windows native framing
tests. Live compatibility with a particular Qwen sidebar version must still be
verified in the user's browser before calling that extension supported. No
third-party extension has been installed or altered by building these files.
