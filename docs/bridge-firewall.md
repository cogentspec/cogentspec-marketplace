# Bridge type and AI-variant firewall

The supported matrix is Snap/GPT, Snap/Claude, Web/GPT, Web/Claude, Web/Qwen,
Desk/GPT, Desk/Claude, and Local/Qwen. Unsupported cells have no fallback.
Execution host, package host, route surface, command type, and AI variant are
different fields. Existing route aliases remain explicit compatibility entries.

`bridge/firewall.json` declares dependency ownership and required automated
contracts. `bridge/locks/<type>/<variant>.json` locks each command's complete
declared source inventory by content hash. These locks are reviewed inputs;
builds never regenerate them. Text hashes canonicalize Git CRLF/LF only; binary
inputs, retained test logs, and release archives use their exact bytes.

The current shared controllers and worker helpers are **legacy shared runtime**.
They are not claimed to be eight independent implementations or safe primitives.
Changing one of those files affects every declared consumer, and adopting only
one command is refused. The initial firewall freezes their existing behavior
instead of rewriting functioning connection flows. New command-specific modules
belong under their type/provider boundary; crossing into another command's
orchestration is rejected. A new shared category cannot be introduced as a
private command edit: the policy and verifier are themselves locked for all
eight commands. There is no unrestricted common/primitive category.

The checker parses JS/TS imports with TypeScript's syntax tree, verifies complete
PowerShell command/core directory inventories, refuses linked inputs and path
escapes, and verifies the actual marketplace package file sets. New helpers and
new dependencies must enter the declared inventory. A source-pattern match alone
does not establish a successful command connection.

`sharedImports` is a closed per-command allowlist of target modules **and exact
exported names**. A Web command allowed to read a document identity cannot start
importing a listener from that same module. Namespace imports, star re-exports,
dynamic module objects and new shared exports do not bypass this boundary.
Expanding the allowlist changes the locked policy and requires all eight
commands' verification. Normal lock adoption never expands it automatically.

## Ordinary verification

From the repository root:

```powershell
node scripts/bridge-firewall.mjs check
node --test scripts/test-bridge-firewall.mjs
```

Marketplace validators invoke the firewall before inspecting packages. The
website's `npm run build` invokes it before compilation. Both repositories have
a Windows CI workflow that checks the firewall and executes the declared
automated matrix. Marketplace verification tools require `npm ci --ignore-scripts`;
the website uses its existing application TypeScript dependency.

## Explicit adoption after a repair

First run `check` and inspect the affected inventories. Do not refresh all locks
to make a build green. Adopt only the exact affected set, with a concrete reason:

```powershell
node scripts/bridge-firewall.mjs adopt --commands web/gpt --reason 'Describe the specific GPTWeb change and its dependencies'
```

If a shared worker, policy, installer, verifier, or test contract changed, the
command prints the larger required consumer set and refuses a narrower scope.
`bridge/adoption.json` records old/new command digests and the stated reason.
Other commands' lock files remain byte-identical during a private adoption.
Their previous source remains recoverable from the pinned Git revision; do not
modify a released revision or overwrite an already published artifact.

Run the source-bound automated contracts for that exact set:

```powershell
node scripts/bridge-firewall.mjs test --commands web/gpt --output artifacts/bridge-verification
```

The runner starts the fixed declared tests with hidden child processes, retains
log hashes, and records the full command/dependency fingerprint. It rejects a
failed, timed-out, or entirely skipped test suite. Integration evidence is never
labelled live. A source, policy, dependency or test change invalidates previous
evidence. Editing an old log invalidates it too.

## Protected release gate

Use the actual previous deployed/published revision as `--base-ref`, not the
candidate revision. The gate compares each candidate command lock against that
revision. Initial introduction of locks requires all eight commands.

```powershell
node scripts/bridge-firewall.mjs affected --base-ref <previous-release>
node scripts/bridge-firewall.mjs release --base-ref <previous-release> --evidence artifacts/bridge-verification/integration.json --live-directory artifacts/bridge-verification/live
```

The release gate requires source-bound passing integration evidence **and fresh
live observations for every affected command**. Missing live evidence is a
release failure, not a skip or an inferred pass. Required fields include exact
command, fresh acknowledgement, connected workspace, visible connected status,
authorized project access, no extra tab, no unexpected startup window and no
duplicate approval. A worker's ready response cannot qualify.

`record-live` accepts an observation made during an authorized real command test:

```powershell
node scripts/bridge-firewall.mjs record-live --command web/gpt --result <private-observation-file> --output artifacts/bridge-verification/live
```

The input must declare the actually tested `testedSourceFingerprint` and
`testedArtifactDigest` (not merely the currently checked-out source),
`environment: live`, `command`, `observedAt`,
`status: connected`, `workspaceConnected: true`, `acknowledgementVerified: true`,
`browserOpened: false`, `visibleBridgeConnected: true`,
`projectLibraryVerified: true`, `duplicateApproval: false` and
`unexpectedWindow: false`. This is an explicit observation attestation, not a
mechanism that turns unchecked booleans or fixture outputs into actual browser
verification. Do not populate it without observing those results. The recorder
retains only this allowlisted summary and source identity, never credentials,
context keys, private workspace URLs or protected handoff material.

The command does not initiate a connection, install software, operate a tab, or
approve ownership. Normal `$gptsnap` behavior gets no new question, gate or UI.
Any real ownership choice remains in the existing site tab.

## Shared-runtime limit

Per-command source locks do not make the running worker, account service or
database physically independent. Changes to those shared services require every
affected command's compatibility checks and live evidence, including supported
previous clients. Future extraction into separately deployable immutable command
artifacts must retain this rule; do not mistake client version pins for server
isolation. Security policy and credential storage remain authoritative and shared.

The current buttons, labels, short in-button copy feedback, help text, workspace
identities, account/device checks and explicit tab ownership remain protected by
the existing behavior tests. The website's Web procedure URLs are pinned to an
exact marketplace revision rather than mutable main-branch instructions.
