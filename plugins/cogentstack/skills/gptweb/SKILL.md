---
name: gptweb
description: Connect the existing CogentSpec GPTWeb tab through browser tools and its approved local Bridge. Use when the user explicitly invokes $gptweb.
---

# Connect the existing CogentSpec GPTWeb work area

This is a self-contained browser procedure. Follow it directly; do not load a generic connection skill, run an updater or launcher, install a ChatGPT plugin, request Windows execution, or send the user to Codex. The AI host may run Linux: only its browser tools are required. The authorized local Bridge must already be running on the user's approved computer; browser permission cannot install or start that process.

1. Discover the host's browser tools. If browser access requires approval, request it through the host's actual approval flow and wait. While approval is pending, report waiting for browser permission. If browser tools are unavailable, report that capability accurately; do not invent an approval prompt.
2. Inspect and claim only the intended existing `cogentspec.app/stack?experience=web&surface=chatgpt` tab. A bound tab may also have a context parameter. Preserve its URL, drafts, parent folder and account. Do not open, navigate, reload or rearrange tabs/windows, choose a project, or substitute another command.
3. In that tab select the single header control **Initiate Bridge**. This is the first connection action: it requires neither a tab listener nor an AI-side Windows executor. The page checks the signed-in account, current accepted device and fresh local worker. If it reports no approved/running Bridge, multiple workspaces, another owner or another error, report its exact message and stop. Do not select a different workspace, run an installer, approve a device or transfer ownership automatically.
4. Read the confirmation's computer, workspace and projects folder. Ask the user to confirm that these are the intended computer/workspace. Keep the confirmation open while waiting. Only after confirmation select **Connect this tab**. The page performs the protected handoff, binds this document, receives its fresh acknowledgement and checks live worker and project-library authorization. No credentials or one-use grants are returned to the AI.
5. Verify that the same tab visibly shows **Bridge connected**, its assigned context matches the confirmed workspace, and **My projects** loads without an authorization or missing-context error. An empty authorized library is valid. Do not claim success from a running Bridge, an accepted click or the confirmation alone. If any check fails, report the exact observed failure.
6. Only after all checks say: **CogentSpec GPT web workspace is connected. Continue beside this conversation.**

The command copy button includes the canonical marketplace link to this procedure. No ChatGPT plugin, skill installation, PowerShell execution or waiting listener is required. Do not invoke `scripts/start-gptweb.ps1` from browser chat; that retained launcher is for an explicitly requested local Windows workflow. This procedure changes only GPTWeb; do not invoke or change GPTSnap, ClaudeSnap, ClaudeWeb, Qwen Web or Qwen Local.
