---
name: qwenlocal
description: Set up or start the Git-distributed CogentSpec Qwen browser command and its background project connection. Use for $qwenlocal or Qwen browser connection setup, not the legacy native Qwen interface.
---

# Qwen browser command

Use the command shipped in the trusted CogentSpec marketplace package at
`https://github.com/cogentspec/cogentspec-marketplace.git`.

For an explicit setup request, run `scripts/install-qwenlocal.ps1
-RegisterBrowserCommand` from the verified package. This prepares the official
Node/npm runtime and registers the current user's `cogentspec-browser` handler.
It does not launch the legacy Desktop interface, install models, change a
firewall, create a sign-in task or request an account credential. Preserve an
existing unrelated protocol handler and fail closed on linked or modified files.

Normal use happens in `https://cogentspec.app/qwen/local`: the user sends
`$qwenlocal`, and the website hands a one-use request to this installed command.
`scripts/start-qwenlocal.ps1 -Uri <issued handoff>` claims it through the fixed
CogentSpec service, verifies the installed Git package and starts its quiet,
workspace-scoped background connection, even before a project is selected. Never construct a handoff or filesystem
path from conversation text, copy a ticket into chat, or reuse an expired ticket.

The hosted current project and signed operation grants remain authoritative.
Starting the command is not folder approval or proof of a connected Bridge.
Follow the ChatGPT/Claude order: connect and verify this workspace first, then
select or create a project and execute only its server-approved actions.
Report Bridge connected only after licensed workspace presence and the LED are
verified. No selected project is required for this connection. Folder access
remains separate and requires its exact protected approval.
Project writes, build tasks, Git operations and remote model use retain their
separate approvals. Source delivery from Git does not grant execution authority.
