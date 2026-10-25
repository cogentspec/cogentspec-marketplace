# GPTWeb browser-handler boundary

This artifact belongs only to Web/GPT. No existing plugin package, Snap/Desk
launcher, worker, manifest, release tag or account credential is changed by
building or installing it. The account-bound credential is read using the
installing Windows user's existing protection; installation does not replace it.

`runtime/skills/cogentspec/scripts` is a frozen source snapshot from marketplace
revision e29ee568d816f7d4afb1b1436035e8b8783556d5. Private changes namespace
launcher state under `CogentSpec/gptweb-browser` and the worker mutex under
`CogentSpecGPTWebBrowser`, and replace the account connector with a Web/GPT-only
read-only adapter. It cannot renew, remove or replace shared credentials.
Snapshot updates require an explicit new artifact
inventory and Web/GPT verification; builds never refresh it from shared code.

`files.sha256` pins every executable input, including this handler, installer and
snapshot. Setup and each handler invocation verify it. `install.ps1` installs
into a content-addressed directory and registers only `cogentspec-gptweb` for the
current Windows user. Another installation's handler is never overwritten.

There is no arbitrary-command request field or general execution service. The
protocol accepts one expiring request ID. The service determines its account and
GPTWeb context. The protected local credential must prove the same approved
device before worker startup. Startup readiness cannot grant tab ownership or
count as a successful browser connection. Browser binding, fresh acknowledgement,
visible live status and project-library authorization remain separate checks.
