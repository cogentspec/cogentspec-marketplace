# GPTWeb setup and connection status

Applies only to `$gptweb`. ClaudeWeb, Snap, Desk and Qwen retain their own procedures.

The user first selects **Set up GPTWeb** in the intended CogentSpec work area, opens the downloaded setup file and accepts any Windows confirmation. Setup downloads the verified helper from this Git marketplace. It starts a GPTWeb-only background helper under that Windows user and registers it to start at sign-in. The page retains its own account, device and tab proofs and completes its protected acknowledgement. Subsequent setup requests can be handled quietly by the running helper.

When the user sends the full copied `$gptweb` command:

1. Read its exact HTTPS verification URL using an ordinary HTTP/web read. This is a short-lived, read-only connection-status capability. Keep the URL private. Do not use browser control or request a Windows execution connection.
2. Report the work area connected only if the response has protocol `cogentspec-gptweb-setup-v1`, command `$gptweb`, `workspaceConnected:true` and `acknowledgementVerified:true`. An installer download, an old success message or a running process is not this proof.
3. A copied link may report `setup_required` before the computer helper is running. Explain that the user should select **Set up GPTWeb** in the existing work area and open the downloaded file. Keep the same verification URL and check it again after setup. Do not request another copy because setup is pending. The copied link remains valid through setup and connection.
4. For `connecting`, report that connection is in progress and recheck the same URL, respecting `retryAfterSeconds`, for up to one minute. If it is still waiting, report the exact status and retain the URL for the next check. Waiting is not connection success or a clipboard failure.
5. If the URL is absent, ask for the full command from the existing work area's copy button. If it has expired or its request was replaced, ask for a fresh copy. For an explicit connection failure, report its message and the setup action it requires. Do not substitute another tab or work area, run an installer from the AI session, use an Initiate Bridge button, request browser debugging or install a plugin.

This acknowledgement verifies the work area's local project helper. It does not create an AI file/shell tool or grant arbitrary access to the PC. Use only project capabilities actually exposed to this AI session and report any missing capability accurately.
