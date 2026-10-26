# GPTWeb after computer setup

Applies only to `$gptweb`. ClaudeWeb, Snap, Desk and Qwen retain their own procedures.

The user first selects **Set up GPTWeb** in the intended CogentSpec work area, opens the downloaded setup file and accepts any Windows confirmation. Setup downloads the verified helper from this Git marketplace. It starts a GPTWeb-only background helper under that Windows user and registers it to start at sign-in. The page retains its own account, device and tab proofs and completes its protected acknowledgement. Subsequent setup requests can be handled quietly by the running helper.

When the user sends the full copied `$gptweb` command:

1. Read its exact HTTPS verification URL using an ordinary HTTP/web read. This is a short-lived, read-only connection-status capability. Keep the URL private. Do not use browser control or request a Windows execution connection.
2. Report the work area connected only if the response has protocol `cogentspec-gptweb-setup-v1`, command `$gptweb`, `workspaceConnected:true` and `acknowledgementVerified:true`. An installer download, an old success message or a running process is not this proof.
3. If the URL is absent, expired, unavailable or reports a failure, ask the user to select **Set up GPTWeb** in their existing work area and copy the command again. Do not substitute another tab or work area, run an installer from the AI session, use an Initiate Bridge button, request browser debugging or install a plugin.

This acknowledgement verifies the work area's local project helper. It does not create an AI file/shell tool or grant arbitrary access to the PC. Use only project capabilities actually exposed to this AI session and report any missing capability accurately.
