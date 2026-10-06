# Rejected Popout lifecycle prototype — not a product dependency

The user rejected browser-extension installation on 2026-10-06. The production watcher source no longer consumes this channel or starts its native lifecycle controller. Do not install, register, publish or recommend this prototype as a fix. Files are retained only as historical test/reference material; the installation instructions below describe the rejected candidate, not a supported onboarding flow.

This Chrome/Edge extension and local Windows native host are not installed or physically accepted yet. No credentials or chat contents are read; no shortcuts are synthesised.

Load this folder unpacked in `chrome://extensions` or `edge://extensions`. This browser permission step is user-operated. Copy its extension ID, then register that exact origin using `register-native-host.ps1 -ExtensionId '<ID>' -Browser Chrome` (or Edge). Reload the extension and require its status to say local host connected.

The matching candidate Bridge is **0.6.90**, installed using the protected existing-installation update protocol. Version 0.6.89 cannot use this channel. Do not overwrite its cache or start a second competing worker. Publication/installation is not physical acceptance.

Snapshots contain only workspace tab/window IDs, active flags and state. Only HTTPS CogentSpec `/stack` and `/workspace` routes qualify, not marketing pages. Native messaging is local; no server requests are made.

The host verifies its registered origin and browser parent process. The controller binds a verified Popout to a foreground CogentSpec browser session and fails closed on ambiguity. One browser/profile is the initial acceptance scope; incognito is not enabled. Existing account and exact-chat gates remain authoritative for the LED.

Hide/restore preserve the same HWND, use no keys and do not steal focus. Focus in the Popout is protected. Manual reveal while away is respected until return. Manual close is not automatically reopened. Last workspace removal requests close after 15 seconds; refresh preserves tab ID, and another workspace cancels closure. Disconnect/stale snapshots are unknown, not proof of closure. Browser process death is checked independently.

Requested, confirmed and failed native operations are separate diagnostics. Pure model tests do not prove physical success. Run the full `CogentSpec/deploy/POPOUT-ACCEPTANCE.md` matrix with the user operating ChatGPT Desktop; the Computer Use skill prohibits automating that UI.

Removal is not automated. Remove the extension and only its dedicated native messaging registration and `%LOCALAPPDATA%\CogentSpec\browser-lifecycle` installation after the host stops. Never remove credentials, projects or general Bridge runtime.
