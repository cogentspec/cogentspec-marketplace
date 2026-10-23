---
name: claudedesk
description: Connect the current isolated Claude Code Desktop project to its Claude-labelled CogentSpec workspace. Use only when the user explicitly invokes $claudedesk or asks for the Claude Desktop command.
---

# Open the CogentSpec Claude Desktop workspace

## User-command experience

A bare Bridge command is a connection request, not a debugging, audit or project-work request. Give one brief startup acknowledgement, perform the required checks privately, and finish with only this destination's prescribed short outcome and any required workspace link. Do not append a verification checklist, project names/counts, version/timing report, proof screenshot or CPD commentary unless the user asks or the host requires it.

Keep the normal current-package command within a one-minute interaction budget (or the destination helper's existing bounded budget). Go directly through its one-shot update/context/start/open/verify flow. Do not search repositories or chat history, run tests, collect optional diagnostics, reload unrelated skills, generate evidence files or rearrange windows. Reuse the already claimed intended browser when available; still live-claim it before navigation. Browser-tool destinations still require matching context, consumed handoff, visible **Bridge connected**, and an authorized **My projects** view; do not select or modify a project.

Interrupt only for a required permission/account approval, ambiguous destination, a verified update, unavailable update check, or failure. Announce a required update briefly and continue the same command. On failure, give the plain user message and supported next action; stop without automatic retries or destination substitution. A ready worker or accepted open is not a verified connection. Keep all existing integrity, privacy, authorization and destination-specific gates. Distinguish partial readiness honestly. Detailed diagnostics are a separate, explicit user request.

If a helper returns `licence_required`, show its plain `userMessage` and stop: this account needs an active CogentSpec licence (an enabled, eligible owner licence counts). Do not start installation, reconnect, computer approval, another command, or a workspace open. Preserve the saved credential. If it returns `licence_verification_unavailable`, report that access could not be checked; do not claim the licence is missing or start approval. A missing credential alone does not prove a missing licence; retain the documented first-time account/device authorization flow only for genuinely unidentified or revoked connections.

This connection-only flow is self-contained; consult `../cogentstack/SKILL.md` only for separately requested project actions. Use `${CLAUDE_PLUGIN_ROOT}` for every bundled path and the invoking Claude project directory, never the cache, marketplace, home or temporary root. Use the host-approved Windows-user execution scope; never bypass required approval or expose protected credentials. If an update was already verified, use only its refreshed plugin root without repeating it. Run `../cogentstack/scripts/project-context.ps1` exactly once and require its isolated context; never infer identity from a title. On any non-ready result, show its plain `userMessage` and supported recovery only, then stop. Do not run the generic connection sequence:

1. Invoke `../cogentstack/scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface claude-desktop -Experience desktop` exactly once.
2. Require `status: ready`, the same isolated `contextKey`, `accountState: signed_in`, and `browserOpened: false`. Require `workspaceUrl` to equal the private `chatgptWorkspaceUrl` on `https://cogentspec.app/stack`, with the matching context, Claude surface and `experience=desktop`. Do not expose either private URL in commentary or logs. This is link readiness, not proof that the browser connected.
3. Return that URL exactly once as `[Open this task’s CogentSpec workspace in Claude](<URL>)`. Do not return the independent web-workspace link unless this destination cannot be prepared.
4. Say: **CogentSpec’s Claude Desktop workspace is ready. Open the link to continue.**

This command selects only the Claude-labelled Desktop destination. It must not call browser control, create or select a tab, resize or join the Claude window, activate ChatGPT Popout behavior, or alter the shared project flow.
