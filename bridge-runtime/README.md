# Standalone GPTWeb Bridge

This is a Windows runtime, not an AI plugin or skill package. It requires neither
Codex nor an additional browser extension. It reuses the public account/device
Bridge protocol and its existing worker. Qwen Local and the plugin packages are
unchanged.

The GPTWeb copy button supplies a self-contained request with the fixed setup
procedure at `https://cogentspec.app/api/bridge/gptweb/setup`. The current AI host
needs approved Windows-user local execution and Git. The request explicitly
continues in that host rather than redirecting to Codex. A bare command typed
into a session which has never received these instructions has no guaranteed
discovery mechanism; the copy button includes the instructions for that case.

The host verifies the public bootstrap SHA-256 before running it. The bounded
bootstrap checks current release metadata, uses a sparse clone of this official
repository only when needed, verifies the complete runtime manifest and every
file, then atomically installs the package beneath
`%LOCALAPPDATA%\CogentSpec\standalone-web`. Matching installed bytes are reused;
modified files, links, unexpected files and wrong source identifiers fail closed.
The bootstrap performs no plugin registration, skill installation, registry
changes, computer approval, credential replacement or browser opening.

The helper keeps the invoking AI workspace as its context. It uses the current
Windows user's existing encrypted Bridge credential and requires fresh worker
presence, the exact destination owner and its live acknowledgement. First-device
or host execution approvals remain explicit. Package installation and worker
readiness never establish a connected result.

`scripts/build-standalone-gptweb.mjs` produces the runtime from the existing public
worker helpers with a standalone manifest reader, a disabled plugin/tool-login
path and the fixed GPTWeb entry. Regenerate it after shared runtime changes. The
builder also publishes the bootstrap and release hashes when passed
`--public-dir <app public/standalone-gptweb directory>`. It does not install or run
the runtime. The public endpoints must not be advertised until the corresponding
runtime source is published on the official repository's main branch.
