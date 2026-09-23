---
name: cogentspec
description: Connect the current Claude Code Desktop project to its isolated CogentSpec Web context through the shared Desktop Bridge; restore portable repository knowledge; fulfil an approved project; generate or restart its verified local preview; prepare an approved deployment handoff; or execute a deletion approved in CogentSpec Web. Use when the user invokes CogentSpec or $cogentspec, asks to connect or open CogentSpec Web, load or edit an existing CogentSpec project, create an approved project, view the active project, prepare a Deployment Pack, or delete a project and its folder.
---

# Use CogentSpec Web through Desktop Bridge in Claude Code Desktop

CogentSpec is a normal web application. Claude Code Desktop remains the official independent AI application. The shared Desktop Bridge connects approved CogentSpec Web actions to this Windows computer; it does not embed, crop, resize, cover, join, inspect, or automate Claude's window. Qwen Desktop is an optional CogentSpec-owned integrated application and reuses the same Bridge rather than installing another copy.

Use `${CLAUDE_PLUGIN_ROOT}` for every bundled script path. Run project-context, Bridge, and project helpers from the invoking Claude project directory, never from the plugin cache, marketplace checkout, user-profile root, or a temporary directory.

## Connect this Claude project

Treat `$cogentspec`, a direct skill invocation, and a natural-language request to connect CogentSpec as the same request.

1. Run `${CLAUDE_PLUGIN_ROOT}\skills\cogentspec\scripts\project-context.ps1` exactly once. Require an isolated context derived from the current Claude project or its bounded workspace. Never guess from a conversation title or use the plugin cache as identity.
2. Run `${CLAUDE_PLUGIN_ROOT}\skills\cogentspec\scripts\start-cogentstack-bridge.ps1 -ContextKey <resolved context> -Surface claude-desktop` exactly once. This helper performs the one account-status check. Require `status: ready`, the same `contextKey`, `accountState: signed_in`, `browserOpened: false`, and private `webWorkspaceUrl` and `chatgptWorkspaceUrl` values on `https://cogentspec.app`. Accept `bridge: started` or `bridge: already_running`.
3. Return both exact work-area links and let the user choose where to open the shared task workspace. Render each choice as a standard Markdown link using `[label](<URL>)`; never emit a raw HTML anchor because Claude displays it as text. Label `webWorkspaceUrl` **Open this task’s CogentSpec workspace in web** and label `chatgptWorkspaceUrl` **Open this task’s CogentSpec workspace in Claude**. Preserve the helper's non-secret `open` and `nav` query parameters: they make every normal click a fresh page navigation even when the same workspace is already open. Each short-lived fragment establishes a separate browser session for the same context and must be returned only as the Markdown link destination, never described or logged separately. Keep `workspaceUrl` only as the compatibility alias and keep `https://cogentspec.com/stack` as the Bridge connection surface. Do not open either workspace link, call browser control, create or select a browser tab, inspect browser profiles, hide the Claude sidebar, resize either window, or create an embedded companion panel. The user decides when and where to open the CogentSpec.app workspace.
4. If the helper returns `signed_out`, explain its exact narrow reason and direct the user to `https://cogentspec.com/install`. Never request a CogentSpec login, licence key, activation code, legal confirmation, account-bound reference, or Desktop credential in the conversation.

Each Claude project receives its own stable logical CogentSpec context. Starting another context does not make CogentSpec appear inside that Claude project and does not create another browser tab. Multiple logical contexts may have background watchers, but the user may keep one physical CogentSpec Web tab and navigate it deliberately.

## Shared installation boundary

- Desktop Bridge is the required small local component for approved project creation, deletion, preview, and repository actions.
- Qwen Desktop is optional and includes or reuses this same Bridge. Never install a second Bridge for Qwen.
- Only one active Desktop Bridge lease exists per CogentSpec account. A confirmed replacement revokes the older lease.
- The Bridge credential is encrypted for the current Windows user with DPAPI. Helpers may use it only against CogentSpec's protected APIs and must never print or expose it.
- The public plugin contains no proprietary contracts, task blueprints, compatibility rules, licence-validation rules, or local substitute project generator.

## Create an approved project

Choosing **Use contract** in CogentSpec Web reveals the exact target checkbox and project-name section. It does not create the project. Local creation is authorized only after the user approves that exact target and selects **Create project** once.

That click saves the authoritative request and queues `create_project` for Desktop Bridge. The web page must keep the approved name, checkbox, target directory, Project Type, pattern, release mode, and Contract Runtime visible and locked while pending. It must not refresh or expose completion before the Bridge creates and verifies the governed foundation.

Desktop Bridge runs `fulfil-project.ps1 -Mode create -RequestId <approved UUID> -ContextKey <context>`. It accepts only the server-authoritative request, verifies the exact target and server-issued artifact, installs dependencies, runs acceptance checks, creates the initial Git baseline, and completes the protected lifecycle. It must never substitute a local template.

Manual recovery from Claude is permitted only when the automatic action queue was unavailable:

1. Run `fulfil-project.ps1 -Mode inspect -ContextKey <context>`.
2. If the sole current request is approved and requested, run `fulfil-project.ps1 -Mode create -RequestId <UUID> -ContextKey <context>` once.
3. If authorization is missing, preserve the request and direct the user to reinstall Desktop Bridge. Do not ask them to repeat contract selection, target approval, project name, brief, login, licence, or legal acceptance.
4. On success, report the exact target, tests, and baseline commit. Continue the project work only inside that created target.

## Restore portable project knowledge

Generated projects carry `AGENTS.md`, `PROJECT_KNOWLEDGE.md`, `CURRENT_STATE.md`, `HANDOFF.md`, `docs/decisions/`, and `.coge/knowledge-manifest.json`. These versioned files—not conversation history—carry durable architecture, decisions, constraints, tests, risks, current state, outstanding work, and safe project identity. Protected contract state remains on CogentSpec.

When an existing project is loaded into a different Claude project:

1. Load it in CogentSpec Web's **Edit project** view for the current logical context.
2. Run `project-knowledge.ps1 -Mode inspect -ContextKey <context>` once.
3. Verify the manifest request identifier matches the protected active project and read the bounded knowledge files before proposing changes.
4. Do not run `git pull` automatically. Show the branch, revision, dirty state, and intended Git operation; fetch or fast-forward only after explicit authorization and never overwrite dirty work.
5. Before an approved commit or handoff, update the human knowledge files and run `project-knowledge.ps1 -Mode refresh -ContextKey <context>`.

The hosted **Check project** control is read-only and queues `refresh_project_git` for Desktop Bridge. The Bridge runs `inspect-project-git.ps1` against the exact protected active-project path, verifies the portable project identity, records the bounded Git snapshot, and completes the check automatically. Do not ask the user to send another Claude command for this check.

For a legacy project, initialize missing portable knowledge only after an explicit request by running `project-knowledge.ps1 -Mode initialize -ContextKey <context>`. It must not overwrite existing files or invent undocumented history.

## Generate or open the active preview

The compact active-project card in CogentSpec Web provides **View project** while its verified preview is live and **Open saved preview** or **Start project preview** when it is stopped. Selecting the start control queues `preview_project` for Desktop Bridge.

The Bridge runs `generate-project-preview.ps1 -Mode generate -ContextKey <context>`, accepts only the exact protected active project path, prefers its saved port, and verifies listener ownership, process ancestry, loopback address, and health before opening the preview. It never navigates the CogentSpec workspace away from its web address.

Manual Claude recovery may run that helper once only when the hosted preview action was unavailable. Treat only `generated` or `already_running` with `remembered: true` as success. Never trust a conversational path, arbitrary localhost service, stale port, or unrelated process.

## Delete an approved project and folder

Typing the exact project name and selecting **Delete project and folder** in CogentSpec Web is the single permanent-deletion confirmation. Loading that project into the current Claude context is not required. The web request immediately queues `delete_project` for Desktop Bridge.

Saved specification drafts use the same protected deletion pattern through `delete-specification-project.ps1`; the helper verifies the exact registered folder and its `.coge/specification-draft.json` identity before removing the folder and saved draft record.

The Bridge runs `delete-project.ps1 -Mode delete -RequestId <approved UUID> -ContextKey <context>`. It accepts only the server-returned deletion and project identifiers, the registered child path, approved parent, slug, and short-lived execution grant. It refuses roots, files, temporary validation paths, reparse points, mismatched parents, and conversationally supplied substitute paths.

If the Bridge has not claimed the request promptly, the page preserves the approval and offers a retry without requiring the project name again. Manual recovery may inspect and execute only that sole authoritative request. Treat success as proven only by `status: deleted`, and report the exact target plus `folderRemoved` and `registrationFinalized` accurately.

## Prepare an independent deployment handoff

Only after the user generates a Deployment Pack from CogentSpec Web's **Hosting** view:

1. Inspect with `prepare-deployment.ps1 -Mode inspect -ContextKey <context>`.
2. Prepare with `prepare-deployment.ps1 -Mode prepare -RequestId <UUID> -ContextKey <context>`.
3. Report the exact project folder and generated `DEPLOYMENT.md` and `deployment.manifest.json`.
4. Do not connect, push, or deploy during preparation. A recorded destination is not authorization to use it.
5. A later deployment requires explicit approval of the exact repository, branch, host, port, directory, health URL, and local actions. Use only existing Git and SSH credentials and never request or expose secrets.

## Hard boundaries

- Never manipulate Claude's application window or private conversation interface.
- Never open, close, select, inventory, or repurpose browser tabs as part of `$cogentspec`.
- Never fall back to an embedded panel, localhost CogentSpec workspace, `/activate`, an older launcher, or a window-arranging helper.
- Never claim sign-in from a local credential file alone; only the protected status response is authoritative.
- Never infer, cache, reveal, or recreate protected contract content.
- Never commit, push, deploy, delete, or perform another material repository action without the corresponding explicit user or hosted-workspace authorization.
