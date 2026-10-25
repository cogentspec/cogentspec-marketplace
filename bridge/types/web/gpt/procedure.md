# GPTWeb quiet setup and connection, version 1

`$gptweb` is a connection command. Keep its normal execution quiet: no running
commentary, diagnostic checklist, repository search, extra AI question, or
success claim before verification. The user's Windows computer runs the helper;
the AI's execution host may be Linux and needs only its actual browser tools.
Never install an AI plugin, skill package, Codex CLI or additional browser
extension, and never substitute another Bridge command.

1. Obtain the host's browser access through its actual approval flow if required.
   While permission is pending, report waiting for permission. Do not invent a
   Windows execution approval or treat browser permission as Windows permission.
2. Claim only the intended existing CogentSpec tab with `experience=web` and
   `surface=chatgpt`. Preserve its URL, account, drafts, parent folder and project
   selection. Do not open, navigate, reload or rearrange tabs/windows.
3. The existing **$gptweb** copy button starts GPTWeb's own protected startup.
   If startup has not begun, select that button once; open **GPTWeb help** first
   only if the button is hidden. There is no Initiate Bridge step and no waiting
   listener. The dedicated Windows app installs once, then starts or reuses the
   helper quietly. Do not execute PowerShell in the AI host.
4. On first use only, let the user complete **Set up GPTWeb once**, Windows/browser
   application consent and any genuine account/device approval in the provided
   setup UI. Do not add an AI question, approve a different device, or bypass OS
   consent. If a genuinely different tab owns the connection, leave the single
   **Move GPTWeb to this tab?** choice for the user. Never select **Use this tab**
   automatically. Routine connection and same-tab reconnect need no such choice.
5. Require the same tab's fresh acknowledgement, visible **Bridge connected**
   status, matching assigned context, and an authorized **My projects** view.
   An empty authorized library is valid. Native helper readiness alone is not
   connection. If a check fails, report the exact page message once and stop;
   do not pick another context, install a different connector, or retry in a loop.
6. Only after those checks say: **CogentSpec GPT web workspace is connected.**

The Windows helper fetches SHA-pinned standalone resources from the official
CogentSpec marketplace. It protects its credential with Windows CurrentUser
DPAPI and sends no credential, browser grant or workspace URL to the AI. Its
native URI carries only an expiring request identifier bound to the signed-in
account and this tab. GPTSnap, ClaudeSnap, ClaudeWeb, Qwen Web, both Desk variants,
Qwen Local and their launchers remain separate.
