---
name: cogentspec
description: Connect the current ChatGPT, Codex, or Claude project to its isolated CogentSpec Web context through Desktop Bridge; restore portable repository knowledge; fulfil or build an approved project; generate its verified local preview; prepare an approved deployment handoff; or execute a deletion approved in CogentSpec Web. Use when the user invokes CogentSpec, $cogentspec, or @cogentspec, asks to connect or open CogentSpec Web, load or edit an existing CogentSpec project, create an approved project, says Build my project or Start Project Build, views the active project, prepares an approved Deployment Pack, or deletes a project and its folder.
---

# Use CogentSpec Web through Desktop Bridge

CogentSpec is a normal web application. Official ChatGPT, Codex, and Claude desktop applications remain separate. The installed Desktop Bridge connects approved web actions to this Windows computer; it does not embed, crop, resize, cover, or join another application's window. Qwen Desktop is an optional CogentSpec-owned integrated application and includes the same Bridge rather than installing another copy.

Resolve the current ChatGPT Project or Codex work area with `scripts/project-context.ps1`. Its one-way, non-secret context key is the logical project identity. Pass it through every protected request and helper. Each context has independent contract, request, active-project, Git, preview, and deployment state. The completed-project library remains shared. Never guess a context from a conversation title and never use a broad home, temporary, plugin-cache, or marketplace directory as project identity.

Run helpers from the invoking task's workspace directory, never from the plugin cache or marketplace checkout.

## Windows execution permissions

Before the one-shot connection helpers, select the host-approved execution scope. The update check needs outbound service access; Bridge startup and the connection helper additionally need the installing Windows user's CurrentUser-protected credential and desktop session. A dedicated Codex sandbox account cannot decrypt that credential. Do not diagnose this as a revoked or broken installation.

In Codex, invoke the exact verified helper through `exec_command` with `sandbox_permissions: require_escalated` and a narrowly scoped justification for that helper's service and Windows-user access. Use the host's approval mechanism, not script self-elevation. Preserve the invoking workspace, thread identity, context key, and helper arguments. `project-context.ps1` can run in the normal sandbox. Marketplace refresh and the protected updater also require approved execution when network or Windows-user access is restricted. This execution approval is separate from approval to update the package; never bypass a required host approval.

Choose this scope before running a helper, rather than attempting it in the sandbox and automatically retrying. If approval is denied or unavailable, stop and explain the permission requirement. If a helper returns `execution_permission_required`, show its plain `userMessage`; do not reinterpret it as `signed_out`, continue the connection, recommend reinstalling, or claim that the LED should be green. Never disable the sandbox globally, change account permissions, copy or expose credentials, or launch a broker or scheduled task to bypass approval.

## Connect the current AI project

Treat `$cogentspec`, `@cogentspec`, a CogentSpec plugin mention, and a natural-language request to connect or open CogentSpec as the same request.

Before connecting, keep the installed Bridge package current:

1. Run `scripts/check-cogentspec-update.ps1 -Surface chatgpt` exactly once from the invoking workspace.
2. If it returns `status: update_available`, tell the user that the verified Bridge update is being installed. Do not ask the user to copy an update prompt, approve the routine update, sign in, provide a licence or activation code, or supply an installation reference.
3. Inspect `codex plugin marketplace list --json` and require the `cogentstack` marketplace source to be exactly `https://github.com/cogentspec/cogentspec-marketplace.git`. Run `codex plugin marketplace upgrade cogentstack --json` once, inspect the refreshed marketplace once more, and require the checked-in installer beneath that exact root: `.agents/plugins/install-cogentspec.ps1` for `pluginId: cogentspec` or `.agents/plugins/install-cogentstack.ps1` for `pluginId: cogentstack`.
4. Run that installer exactly once with `-UpdateOnly -MarketplacePrepared -InstallerTimeoutSeconds 120`. Pass no account-bound request or Desktop credential. Require `protocol: trusted-marketplace-update-v1`, `status: updated`, `credentialPreserved: true`, `previousPackageReplaced: true`, `packageRuntimeCleared: true`, `workerStateCleared: true`, `popoutBridgeReady: true`, `desktopUiBridgeReady: true`, `projectDataConnectionReady: true`, `continueCurrentTask: true`, `fastUpdatePath: true`, `workspaceReadinessSkipped: true`, `claimAttempted: false`, and `accountRequestConsumed: false`.
5. Continue this same task with the refreshed installed package. Treat the returned `refreshedPluginPath` as the only current package root, resolve every following helper beneath it, and continue directly into project resolution and Bridge startup. Never invoke a pre-update helper path and never tell the user to start a new task.
6. If the marketplace or installer fails, report its exact failed stage and reason. Do not use the first-install flow, reuse an account-bound request, or silently claim success.
7. If the check returns `status: current`, continue normally. If it returns `status: check_unavailable`, do not block an otherwise working Bridge connection; continue and mention that the update check could not be completed.

Then connect the current project:

The routine current-package connection has a one-minute interaction budget. Run the update check, context resolution, Bridge startup, and native workspace open directly, without repository inspection, builds, test suites, repeated helpers, or extra diagnostic work between them. Every helper remains one-shot. If a bounded helper cannot verify readiness within its deadline, return its plain recovery message immediately instead of leaving the user waiting. A verified package update is a separately announced update operation; identify it immediately so its installation time is never mistaken for a stalled Bridge connection.

1. Run `scripts/project-context.ps1` exactly once and require an isolated stable context unless the task is genuinely unscoped.
2. Run `scripts/start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface chatgpt` exactly once. This helper performs the account check and prepares the secure project-data connection before returning. Require `status: ready`, the same `contextKey`, `accountState: signed_in`, `mcpState: ready`, `browserOpened: false`, and private `webWorkspaceUrl` and `chatgptWorkspaceUrl` values on `https://cogentspec.app`. Accept either `bridge: started` or `bridge: already_running`. If it returns `connection_required`, show only its plain `userMessage`; do not mention MCP, OAuth, tool names, plugin paths, or ask the user to repeat a command. If it returns `signed_out`, explain that Desktop Bridge is missing, replaced, revoked, or requires updated legal acceptance according to its exact reason. Direct the user to `https://cogentspec.com/install`; never request a login, licence key, activation code, legal confirmation, or Desktop credential in the conversation.
3. Keep `webWorkspaceUrl` as a recovery destination; do not render it before attempting the native workspace open. If recovery is required, return it once as a standard Markdown link using `[Open CogentSpec workspace](<URL>)`; never emit a raw HTML anchor. Preserve its non-secret `open` and `nav` query parameters and keep its short-lived fragment only in the link destination.
4. Do not render `chatgptWorkspaceUrl` as a Markdown or HTML link. A normal HTTPS link cannot dispatch the desktop host’s Ctrl+T browser-tab action. When the `mcp__codex_app__open_in_codex` tool is available, call it exactly once with `target: { type: "browser", url: chatgptWorkspaceUrl }`. Omit `threadId`, `tabId`, and `placement` so the current task receives a normal in-app browser tab. Treat either `opened` or `queued` as acceptance and do not retry. After either accepted result, do not render `webWorkspaceUrl`. Report **CogentSpec is connected. Continue in the workspace beside this conversation.** only when the launcher also returned `currentConversationConnected: true` (or the legacy `popoutConnectionConfirmed: true`). Otherwise report the launcher's `popoutUserMessage` and bounded `popoutConnectionReason`: the project-data Bridge is ready, but the current Popout conversation is not verified and the workspace remains disconnected. Never omit a false confirmation or timeout from the result, and never treat an accepted workspace open as exact-chat confirmation. This purpose-built app action is permitted; do not use generic browser control, inspect unrelated tabs, hide a sidebar, resize a window, or arrange a split. If the native tool is unavailable or does not return `opened` or `queued`, return only the recovery link and state that the workspace could not be opened automatically. Never claim that a second link opens ChatGPT. The native open must not consume the independent web authorization. Keep `workspaceUrl` only as the compatibility alias for `chatgptWorkspaceUrl`, and keep `https://cogentspec.com/stack` as the Bridge connection surface.
5. Report only the verified connection state and native open result. Readiness without `status: ready` is not a successful connection.

For ChatGPT Popout, treat `currentConversationConnected` as the authoritative exact-chat gate; `popoutConnectionConfirmed` is its compatibility alias. `status: ready`, a running Bridge, or Popout visibility does not prove that the current conversation is connected. Only `currentConversationConnected: true` confirms that the currently selected conversation identity, its verified `$cogentspec` fingerprint, the isolated context, and fresh Bridge presence all match. Hiding the same connected Popout must not disconnect it, while selecting a blank or different conversation must make the gate false. When it is false, do not say that the Popout is connected or imply that the website LED should be green; report that the project-data Bridge is ready but the current Popout conversation is not yet verified, and direct the user to send `$cogentspec` from that intended conversation. Never reinterpret `popupVisible: true` as a connected conversation.

The workspace opened through the native desktop action is the primary destination; the web link is recovery only. Both destinations use the same server-authoritative context, active project, approved decisions, Bridge queue, Git state, preview state, and deployment state. Saved changes refresh from the shared server without copying unsaved browser-local text between views. Switching AI projects changes the context in both destinations, creates two fresh one-use workspace handoffs, and starts or reuses that context's Bridge worker; it does not create permanent CogentSpec browser tabs.

## Current activity required before project instructions

Before resolving any connected project instruction, including discussion or refinement of a new idea, call `get_project_activity` with the freshly resolved invoking context, or `scripts/project-build-handoff.ps1 -ContextKey <context> -ChangeAction activity`. This read is allowed before selection; it is not permission to inspect project files. Require `status: ready` and one specific current project or active new-idea draft. If unavailable, absent, ambiguous or unverified, stop and say exactly: **Please select a project for activity to begin.** Do not choose a target from the conversation, current directory, recent request, tab label, project count or a green Bridge indicator.

A blank New idea page is not a current draft. Ask the user to create/select it in CogentSpec first. A verified draft permits only instructions about that draft; it is not authority to edit or build an existing project. Existing-project work additionally requires a fresh change/build handoff with the same project identity and verified local manifest. Recheck activity before mutations and after any pause or user approval. If its ID or revision changed, stop and clarify the intended target; never transfer a pending instruction to a different selection. Connection, update, and user-directed project-selection/creation controls remain available; this gate must not prevent selecting a project. Never run a build, repair, preview, file inspection or filesystem edit to work around a failed gate.

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

## Build the active approved project

Treat **Build my project** and **Start Project Build** as authorization to implement the current approved project, run its required checks, update its portable knowledge, and generate its first verified preview. This authorization does not include committing, pushing, or deploying.

1. Resolve the current context with `scripts/project-context.ps1` exactly once unless this task already has its verified context key.
2. Run `scripts/project-knowledge.ps1 -Mode inspect -ContextKey <context>` exactly once. Require one active created project, a matching `.coge/knowledge-manifest.json`, and the generated foundation at the exact returned target. Stop on an identity mismatch, dirty unrelated work, or an unverifiable foundation.
3. If the CogentSpec MCP tool `get_project_build_handoff` is callable in the current task, call it exactly once with that exact context key. If the tool is not exposed in this already-connected task, run `scripts/project-build-handoff.ps1 -ContextKey <context>` exactly once instead. Both paths read the same server-authoritative handoff and must require `status: ready`, `command: Build my project`, the same project request identifier, Project Type, Contract Runtime, and Contract Pack as the local manifest. Never ask the user to run `$cogentspec` or repeat **Build my project** merely to refresh task tools. If the protected response includes a bounded `error`, report that exact user-safe reason and confirm that the active project remains saved. If no bounded reason is available, say only that CogentSpec could not start the build and that the active project remains saved. Do not mention MCP, OAuth, tool names, plugin paths, or reconstruct the brief.
4. Use the handoff's original brief, approved direction, refinements, baseline, and build sequence as the build authority. Read the project's `AGENTS.md`, `PROJECT_KNOWLEDGE.md`, `CURRENT_STATE.md`, `HANDOFF.md`, and actual package before editing.
5. Implement the project-specific experience in the existing foundation. Do not replace the approved Project Type or Contract Pack, and do not carry content, styling, paths, ports, or assumptions from another project.
6. Run the project tests, production build, and relevant release checks. Update the portable knowledge files with the implemented decisions, current state, validation evidence, risks, and remaining work.
7. Run `scripts/generate-project-preview.ps1 -Mode generate -ContextKey <context>` exactly once. Accept only `status: generated` or `status: already_running` with `remembered: true`, and require the reported project request identifier and target to match the inspected project.
8. Report the completed project-specific build, checks, exact preview result, and any remaining limitation. Do not create a Git commit, push, or deploy without separate explicit approval.

## Change the connected project (workflow1)

When the user describes changes to the connected active project, treat that as the work request; do not require a copied template, repeated folder path, another connection command, or "Build my project". This authorizes the requested file changes and revised preview, not unrelated baseline changes, commits, pushes or deployment.

1. Resolve the invoking context, then run `scripts/project-build-handoff.ps1 -ContextKey <context> -ChangeAction inspect`. Use the returned active project, registered folder, current project-bound baseline and protected contract identity. Do not use a previous chat's project or a newer unrelated runtime. Verify the local manifest project identity and read repository instructions and portable knowledge before editing.
2. If the request fits the approved baseline, implement it directly while preserving unrelated work. If a setting conflicts, explain the exact conflict and proposed adjustment. Never override protected requirements, project type, identity or folder.
3. For supported web baseline settings, create a JSON proposal payload containing `projectId`, `runtimeId` from the fresh handoff, and `patch` with only the changed editable baseline input fields. Run the same helper with `-ChangeAction propose -ChangePayloadPath <file>`. This saves a proposal, not a baseline change. Show the returned before/after settings and ask the user for explicit approval. Keep their original work request.
4. Only after that approval, create a payload containing the returned `proposalId` and run `-ChangeAction apply -ChangePayloadPath <file> -Approved`. A denial means no apply. Expired, changed-project or stale-baseline rejection requires a fresh read/proposal and fresh approval, not an automatic retry. Conversational updates currently cover the editable web baseline fields returned by the handoff; unsupported settings require the supported website editor or a supported alternative, never a fabricated update.
5. Require `status: applied`, reread the change handoff, and continue the original implementation without asking the user to repeat it. Verify manifest project identity rather than expecting its creation-time runtime ID to change. Do not alter creation provenance to make checks pass.
6. Run relevant tests/build, update portable knowledge, and generate the revised preview with `generate-project-preview.ps1 -Mode generate -ContextKey <context>`. Require the same project identity and verified preview result; report what changed and any unresolved constraints.

## Restore portable knowledge

New projects contain `AGENTS.md`, `PROJECT_KNOWLEDGE.md`, `CURRENT_STATE.md`, `HANDOFF.md`, `docs/decisions/`, and `.coge/knowledge-manifest.json`. Git carries durable project knowledge; CogentSpec restores protected server state through the safe project request identifier.

When an existing project is loaded in another AI project:

1. Load it in CogentSpec Web for the current logical context.
2. Run `scripts/project-knowledge.ps1 -Mode inspect` once.
3. Read the returned knowledge before changing the project.
4. Never run `git pull` automatically. Show branch, revision, dirty state, and proposed Git action; fetch or fast-forward only after explicit approval and never overwrite dirty work.
5. Before an approved handoff or commit, refresh the knowledge state and update the human knowledge files when architecture, decisions, tests, risks, or outstanding work changed.
6. For a legacy project, initialize missing portable knowledge only after an explicit request and never invent undocumented history.

The hosted **Check project** control is read-only and queues `refresh_project_git` for Desktop Bridge. The Bridge runs `inspect-project-git.ps1` against the exact protected active-project path, verifies the portable project identity, records the bounded Git snapshot, and completes the check automatically. Do not ask the user to send another ChatGPT command for this check.

Selecting hosted **Save version** with a valid description is explicit authorization for that one local Git commit. It queues `save_project_git` for Desktop Bridge, which runs `save-project-version.ps1` against the exact protected active-project path, verifies the project identity and Git author, commits the current project changes with the approved description, records the resulting snapshot, and completes automatically. It does not push or deploy. Do not ask the user to send another ChatGPT command for this save.

Selecting **Restore this version** on an older saved version and confirming the named version is explicit authorization to restore that exact historical Git tree. It queues `restore_project_version` for Desktop Bridge, which runs `restore-project-version.ps1`, requires a clean verified project, accepts only an ancestor from the current project history, restores its tracked files, and records the result as a new commit without erasing the existing history. It does not push or deploy. Do not ask the user to send another ChatGPT command for this restore.

## Generate or restart the active preview

The hosted **Open saved preview** button queues `preview_project` for Desktop Bridge after a project-specific preview has already been recorded. The Bridge runs `scripts/generate-project-preview.ps1 -Mode generate -ContextKey <context>`, requires the protected service to authorize the exact active request and registered folder in the current context, verifies the stable project identity from `.coge/knowledge-manifest.json`, requires at least one real implementation file to differ from the generated Git foundation, then verifies that the listener and process tree belong to that exact project. The manifest context records creation provenance and does not permanently bind a completed portable project to its original AI context. Only then may the Bridge record the healthy loopback URL and open it in the user's normal browser. A generic foundation, project-identity mismatch, missing identity, or unverifiable Git baseline must fail closed without opening a preview. It never navigates away from the CogentSpec workspace.

The hosted **Prepare handoff** action may generate a reviewed Spec Kit-compatible additive overlay for one completed project. After the user reviews the exact files and approves them, Desktop Bridge runs `scripts/prepare-development-handoff.ps1 -RequestId <approved UUID> -ContextKey <context>`. The helper verifies the registered project identity, execution grant, file paths, and content hashes. It updates a previous CogentSpec handoff only when every existing target still matches the prior recorded hashes; user-edited or unrelated files produce a conflict and no handoff files are changed. CogentSpec remains the contract, evidence, approval, and release authority.

The saved port is a preference, not proof of a live process. Accept only `status: generated` or `status: already_running` with `remembered: true`. Routine viewing of an already-running preview uses the hosted **View project** button and does not invoke an agent.

Manual `@cogentspec view active project` is recovery only: run the generation helper once, do not invent a server or accept a conversation-supplied path or port, and report `no_active_project` or `preview_not_supported` exactly when returned.

## Delete an approved project and folder

Saved specification drafts use the same protected deletion pattern. Typing the exact draft name and selecting **Delete specification and folder** queues `delete_specification`. Desktop Bridge runs `scripts/delete-specification-project.ps1 -Mode delete -RequestId <approved UUID> -ContextKey <context>`, verifies the `.coge/specification-draft.json` identity and exact registered child path, removes the folder, and only then removes the saved draft record.

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
