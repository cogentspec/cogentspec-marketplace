# CogentSpec Marketplace

This repository contains three separate Git marketplaces and release records:

- `.agents/plugins/` and `plugins/cogentstack/` distribute the thin CogentSpec Codex plugin.
- `.claude-plugin/` and `claude-plugins/cogentstack/` distribute the desktop-only CogentSpec plugin for Claude Code.
- `contracts/` publishes the open Community Guardrail Pack protocol and its Git-reviewed registry.

It also publishes the authoritative `desktop/marketplace.json` release record for CogentSpec Desktop. Windows installers are attached to versioned GitHub Releases rather than committed to Git history. The web installer reads this record, verifies the published SHA-256, and keeps Launch visibly disabled until the installed local runtime is detected. Windows always retains the user's approval before executing a first-time installer.

Community Guardrail Packs are declarative. They can define requirements, controls, guidance, and acceptance evidence, but they cannot execute scripts or contain CogentSpec's protected runtime rules. CogentSpec's proprietary engine remains responsible for compatibility review, binding, execution, entitlement, and release decisions.

## Validate the contract marketplace

```bash
node scripts/validate-contract-marketplace.mjs
node scripts/validate-desktop-marketplace.mjs
node scripts/validate-claude-marketplace.mjs
```

Installer readiness regressions exercise both checked-in installers without an account claim:

```powershell
powershell.exe -NoProfile -File scripts/test-installer-workspace-readiness.ps1 -Live
powershell.exe -NoProfile -File scripts/test-installer-v3.ps1 -PluginName cogentspec
powershell.exe -NoProfile -File scripts/test-installer-v3.ps1 -PluginName cogentstack
```

The readiness tests reject redirects, login pages, unexpected origins, non-200 responses, and missing workspace markers. `-Live` additionally checks the public `https://cogentspec.app/stack` shell. The v3 integration tests use isolated local package/claim fixtures, not a real account-bound installation request.

## Claude Code Desktop

The Claude plugin retains `$cogentstack` as the common invocation. It resolves the current Claude Code Desktop project's isolated logical CogentSpec context, starts or reuses the same background Desktop Bridge used by CogentSpec Web and Qwen Desktop, and returns the matching web URL. It does not open or inspect browser tabs, hide the Claude sidebar, resize windows, embed CogentSpec, or automate Claude's private interface.

The explicit `$claudeweb` skill prepares the ordinary Web destination through a dedicated validated launcher. Where approved browser control is available it delivers the one-use handoff to the intended CogentSpec workspace tab; otherwise it returns one recovery link. It reports connected only after the workspace LED and project library are verified. This requires the installed plugin and local helper access; a plain Claude-in-Chrome chat is not itself a local Bridge executor. `$claudedesk` and the general connection command retain their separate link-based flows.

## Qwen browser command

The `qwenlocal` skill is shipped in the same trusted Git package as the other
CogentSpec commands. For the current browser workspace, one-time setup runs its
`scripts/install-qwenlocal.ps1 -RegisterBrowserCommand` from the verified package.
That prepares the official checksum/publisher-verified Node/npm runtime and
registers a current-user `cogentspec-browser` handler. It does not use the legacy
native Qwen interface, install a model, add a sign-in task or open a firewall.

Normal use is simply `$qwenlocal` in `https://cogentspec.app/qwen/local`. The
installed handler claims a one-use, selected-project request from the fixed
CogentSpec service and starts the quiet background connection. No terminal,
downloaded command file, manual pairing code or project refresh is part of the
normal flow. Project grants and signed receipts still enforce the current
account, exact folder and separately approved operation. Handoff dispatch or
model discovery alone cannot claim a connected project.

Run `node --test scripts/test-qwenlocal-command.mjs` to verify package digests,
Windows parsing, validation-before-registration and modified-file rejection.

## ChatGPT and Codex Desktop commands

The Codex plugin is installed from the Git-backed `.agents/plugins/` marketplace and retains `$cogentstack` as the common invocation. It resolves the current AI Project's isolated logical CogentSpec context, starts or reuses one background Desktop Bridge for that context, and returns the matching CogentSpec Web URL. It does not open or select browser tabs, inspect browser profiles, hide sidebars, resize windows, or embed CogentSpec into every AI Project.

Desktop Bridge performs only explicitly approved local actions queued by CogentSpec Web: project creation, deletion, preview generation, and repository operations. Qwen Desktop is an optional separate application and reuses the same Bridge; it does not install a second copy. ChatGPT and Claude remain their official independent desktop applications.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the submission process and `contracts/protocol/v0.1/` for the protocol schema.
