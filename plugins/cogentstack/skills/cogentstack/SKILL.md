---
name: cogentstack
description: Connect the current ChatGPT, Codex, or Claude project to its isolated CogentSpec Web context through Desktop Bridge; restore portable repository knowledge; fulfil an approved project; generate its verified local preview; prepare an approved deployment handoff; or execute a deletion approved in CogentSpec Web. Use when the user invokes CogentSpec, $cogentstack, or @cogentstack, asks to connect or open CogentSpec Web, load or edit an existing CogentSpec project, create an approved project, view the active project, prepare an approved Deployment Pack, or delete a project and its folder.
---

# Use CogentSpec Web through Desktop Bridge

CogentSpec is a normal web application. Official ChatGPT, Codex, and Claude desktop applications remain separate. The installed Desktop Bridge connects approved web actions to this Windows computer; it does not embed, crop, resize, cover, or join another application's window. Qwen Desktop is an optional CogentSpec-owned integrated application and includes the same Bridge rather than installing another copy.

Resolve the current ChatGPT Project or Codex work area with `scripts/project-context.ps1`. Its one-way, non-secret context key is the logical project identity. Pass it through every protected request and helper. Each context has independent contract, request, active-project, Git, preview, and deployment state. The completed-project library remains shared. Never guess a context from a conversation title and never use a broad home, temporary, plugin-cache, or marketplace directory as project identity.

Run helpers from the invoking task's workspace directory, never from the plugin cache or marketplace checkout.

## Connect the current AI project

Treat `$cogentstack`, `@cogentstack`, a CogentSpec plugin mention, and a natural-language request to connect or open CogentSpec as the same request.

Before connecting, keep the installed Bridge package current:

1. Run `scripts/check-cogentspec-update.ps1 -Surface chatgpt` exactly once from the invoking workspace.
2. If it returns `status: update_available`, tell the user that the verified Bridge update is being installed. Do not ask the user to copy an update prompt, approve the routine update, sign in, provide a licence or activation code, or supply an installation reference.
3. Inspect `codex plugin marketplace list --json` and require the `cogentstack` marketplace source to be exactly `https://github.com/cogentspec/cogentspec-marketplace.git`. Run `codex plugin marketplace upgrade cogentstack --json` once, inspect the refreshed marketplace once more, and require the checked-in installer beneath that exact root: `.agents/plugins/install-cogentspec.ps1` for `pluginId: cogentspec` or `.agents/plugins/install-cogentstack.ps1` for `pluginId: cogentstack`.
4. Run that installer exactly once with `-UpdateOnly -MarketplacePrepared -InstallerTimeoutSeconds 120`. Pass no account-bound request or Desktop credential. Require `protocol: trusted-marketplace-update-v1`, `status: updated`, `credentialPreserved: true`, `previousPackageReplaced: true`, `packageRuntimeCleared: true`, `workerStateCleared: true`, `continueCurrentTask: true`, `fastUpdatePath: true`, `workspaceReadinessSkipped: true`, `claimAttempted: false`, and `accountRequestConsumed: false`.
5. Continue this same task with the refreshed installed package. Treat the returned `refreshedPluginPath` as the only current package root, resolve every following helper beneath it, and continue directly into project resolution and Bridge startup. Never invoke a pre-update helper path and never tell the user to start a new task.
6. If the marketplace or installer fails, report its exact failed stage and reason. Do not use the first-install flow, reuse an account-bound request, or silently claim success.
7. If the check returns `status: current`, continue normally. If it returns `status: check_unavailable`, do not block an otherwise working Bridge connection; continue and mention that the update check could not be completed.

Then connect the current project:

1. Run `scripts/project-context.ps1` exactly once and require an isolated stable context unless the task is genuinely unscoped.
2. Run `scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt` exactly once. This helper performs the one account-status check itself. Require `status: ready`, the same `contextKey`, `accountState: signed_in`, `browserOpened: false`, and private `webWorkspaceUrl` and `chatgptWorkspaceUrl` values on `https://cogentspec.app`. Accept either `bridge: started` or `bridge: already_running`. If it returns `signed_out`, explain that Desktop Bridge is missing, replaced, revoked, or requires updated legal acceptance according to its exact reason. Direct the user to `https://cogentspec.com/install`; never request a login, licence key, activation code, legal confirmation, or Desktop credential in the conversation.
3. Return `webWorkspaceUrl` as one standard Markdown link using `[Open this task’s CogentSpec workspace in web](<URL>)`; never emit a raw HTML anchor. Preserve its non-secret `open` and `nav` query parameters and keep its short-lived fragment only in the link destination.
4. Do not render `chatgptWorkspaceUrl` as a Markdown or HTML link. A normal HTTPS link cannot dispatch the desktop host’s Ctrl+T browser-tab action. When the `mcp__codex_app__open_in_codex` tool is available, call it exactly once with `target: { type: "browser", url: chatgptWorkspaceUrl }`. Omit `threadId`, `tabId`, and `placement` so the current task receives a normal in-app browser tab. Treat either `opened` or `queued` as acceptance and do not retry. This purpose-built app action is permitted; do not use generic browser control, inspect unrelated tabs, hide a sidebar, resize a window, or arrange a split. If the native tool is unavailable, return only the web link and state that in-app opening is unavailable; never claim that a second link opens ChatGPT. The native open must not consume the independent web authorization. Keep `workspaceUrl` only as the compatibility alias for `chatgptWorkspaceUrl`, and keep `https://cogentspec.com/stack` as the Bridge connection surface.
5. Report only the verified connection state and native open result. Readiness without `status: ready` is not a successful connection.

The returned web link and the workspace opened through the native desktop action may both be used. Both views use the same server-authoritative context, active project, approved decisions, Bridge queue, Git state, preview state, and deployment state. Saved changes refresh from the shared server without copying unsaved browser-local text between views. Switching AI projects changes the context in both destinations, creates two fresh one-use workspace handoffs, and starts or reuses that context's Bridge worker; it does not create permanent CogentSpec browser tabs.

## Account and service boundaries

- The plugin package and unprotected Project Type browsing are public. Protected credentials and project-changing actions are not.
- The installation page supplies one opaque, single-use account-bound reference after explicit legal confirmation. Never recover or reuse one from an earlier message, file, log, clipboard, task, or memory.
- The installer stores a DPAPI-protected access and renewal credential for the current Windows user. Never display, copy, or transmit those values except through the supplied connection helper.
- Only one active Desktop Bridge lease exists per account. Installing Qwen Desktop uses that same lease and Bridge.
- CogentSpec's protected server is authoritative for contract selection, project artifacts, compatibility, execution grants, and lifecycle state. Do not infer or reconstruct proprietary contract content locally.

## Create an approved project

Selecting **Use contract** reveals the target checkbox and project name. No project request exists until the user approves the exact target and selects **Create project**.

That click creates the authoritative project request and queues `create_project` for Desktop Bridge in one web operation. It must not navigate, refresh, clear, or unlock the approved name, checkbox, directory, Project Type, pattern, release mode, or Contract Runtime. While queued, show only a compact pending state. Show completion only after the Bridge has claimed the request and the protected service has verified the generated foundation.

Desktop Bridge runs `scripts/fulfil-project.ps1 -Mode create -RequestId <approved UUID> -ContextKey <context>`. The helper accepts only the server-authoritative request, verifies the returned artifact and exact target, installs dependencies, runs acceptance checks, creates the baseline Git commit, and completes the server lifecycle. It must never substitute a local template.

Manual recovery is allowed only when the automatic Bridge queue is unavailable:

1. Run `scripts/fulfil-project.ps1 -Mode inspect -ContextKey <context>`.
2. If exactly one current request is returned, run `scripts/fulfil-project.ps1 -Mode create -RequestId <id> -ContextKey <context>` once.
3. If authorization is required, run connection status once and retry only when it renews successfully. Preserve the approved request and never make the user repeat the contract, name, target, checkbox, login, licence, or legal confirmation.
4. On success report the exact target path, tests, and baseline commit. Do not push, deploy, or create another commit without explicit approval.

## Restore portable knowledge

New projects contain `AGENTS.md`, `PROJECT_KNOWLEDGE.md`, `CURRENT_STATE.md`, `HANDOFF.md`, `docs/decisions/`, and `.coge/knowledge-manifest.json`. Git carries durable project knowledge; CogentSpec restores protected server state through the safe project request identifier.

When an existing project is loaded in another AI project:

1. Load it in CogentSpec Web for the current logical context.
2. Run `scripts/project-knowledge.ps1 -Mode inspect` once.
3. Read the returned knowledge before changing the project.
4. Never run `git pull` automatically. Show branch, revision, dirty state, and proposed Git action; fetch or fast-forward only after explicit approval and never overwrite dirty work.
5. Before an approved handoff or commit, refresh the knowledge state and update the human knowledge files when architecture, decisions, tests, risks, or outstanding work changed.
6. For a legacy project, initialize missing portable knowledge only after an explicit request and never invent undocumented history.

## Generate or restart the active preview

The hosted **Open saved preview** or **Start project preview** button queues `preview_project` for Desktop Bridge. The Bridge runs `scripts/generate-project-preview.ps1 -Mode generate -ContextKey <context>`, verifies the project request and context identity from `.coge/knowledge-manifest.json`, requires at least one real implementation file to differ from the generated Git foundation, then verifies that the listener and process tree belong to that exact project. Only then may it record the healthy loopback URL and open it in the user's normal browser. A generic foundation, identity mismatch, missing identity, or unverifiable Git baseline must fail closed without opening a preview. It never navigates away from the CogentSpec workspace.

The saved port is a preference, not proof of a live process. Accept only `status: generated` or `status: already_running` with `remembered: true`. Routine viewing of an already-running preview uses the hosted **View project** button and does not invoke an agent.

Manual `@cogentstack view active project` is recovery only: run the generation helper once, do not invent a server or accept a conversation-supplied path or port, and report `no_active_project` or `preview_not_supported` exactly when returned.

## Delete an approved project and folder

Typing the exact project name and selecting **Delete project and folder** is the single explicit deletion confirmation. The web request queues `delete_project` immediately; loading that project into the current AI context is not required. Desktop Bridge runs `scripts/delete-project.ps1 -Mode delete -RequestId <approved UUID> -ContextKey <context>`.

The deletion helper accepts only the matching protected deletion and project identities, exact registered child path, approved parent directory, project slug, and short-lived execution grant. It refuses drive roots, files, temporary validation paths, reparse points, mismatched parents, and manually supplied paths.

If the Bridge has not claimed the queue after 15 seconds, the web page preserves the approval, confirms that the folder is still intact, and offers a retry without requiring the name again. On success, report the exact target and `folderRemoved`. The helper permanently removes the registered folder plus project-linked active selection, runtime, Git, deployment, contract-runtime, measurement, and request records.

Manual deletion is recovery only:

1. Run `scripts/delete-project.ps1 -Mode inspect -ContextKey <context>`.
2. If exactly one approved request is returned, run its delete mode once with that ID and context.
3. Never delete a conversational path manually. If filesystem removal occurred but registration finalization failed, say so precisely and do not retry without a fresh hosted approval.

## Prepare an approved deployment handoff

Only after the user selects **Generate Deployment Pack** in Hosting:

1. Inspect with `scripts/prepare-deployment.ps1 -Mode inspect`.
2. Prepare with `scripts/prepare-deployment.ps1 -Mode prepare -RequestId <id>`.
3. Report the project folder, `DEPLOYMENT.md`, `deployment.manifest.json`, and approved non-secret destination.
4. Do not push or connect during pack preparation. A recorded destination is not execution permission.
5. For a later explicit deployment request, show the exact repository, branch, host, port, directory, health URL, and intended actions before execution. Use only existing Git and SSH credentials; never request or reveal them. Verify the host key and keep all actions within the approved manifest.
