---
name: qwenweb
description: Connect this isolated Qwen project to CogentSpec Web using an authenticated browser handoff.
---

# Open the CogentSpec Qwen web workspace

Use the marketplace package and the approved Windows-user execution tool. No ChatGPT plugin or connector login is required. Qwen browser chat can use the separately registered CogentSpec Qwen Web companion; a plain sidebar does not itself provide local file execution. This flow applies only to $qwenweb, never $qwenlocal or a Snap command.

1. Run scripts/start-qwenweb.ps1 once from the invoking project. Resolve the helper beneath the installed, verified package (or its refreshed root after the trusted update procedure). It starts or reuses the authenticated local Bridge with -Surface qwen-web -Experience web. Do not require an Initiate Bridge listener first or run the shared helpers again.
2. Require status: ready, accountState: signed_in, presenceVerified: true, defaultDirectoryReady: true, projectDataConnection: authenticated_desktop_bridge, mcpState: not_required and browserOpened: false. A ready Bridge is not a connected page. On failure report only the plain userMessage and stop. Never install or approve a device merely to bypass a failure.
3. Claim the intended CogentSpec Qwen Web tab through approved browser tools as qwenWebTab. Require browserNavigationProtocol: cogentspec-qwenweb-navigation-v1 and pass browserNavigationCode directly to that tool once. It contains a destination-validated, one-use Web handoff for this exact context. Preserve drafts before navigation; if the intended tab is ambiguous or contains unsaved work, ask the user before replacing it. If no workspace exists, create one only in the user's identified browser. Do not navigate Qwen's conversation page, change another provider, rearrange windows or pass private material through files, clipboard or logs.
4. Verify the matching context, consumed one-use fragment, visible Bridge connected status and authorized My projects library (an empty library is valid). Only then report connected. The browser companion follows this same sequence through its registered native helper and verifies the resulting page; it never reports a ready worker as connected.
5. If browser delivery is unavailable, return the unconsumed private workspaceUrl once as an Open CogentSpec Qwen web workspace link and report ready only. Do not return a consumed link or retry a failed attempt.

Keep account/device checks, credentials and handoff material private. This connection prepares only the user's default projects parent. Custom parents and project directories retain their approval checks. Preserve this provider's explicit folder choice. Do not run other destination launchers or select a project merely to connect.
