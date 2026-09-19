# CogentSpec update protocol v1

Use this protocol only to update an existing CogentSpec plugin installation. It refreshes the public package and preserves the account-bound Desktop Bridge credential already protected for the current Windows user. It does not create or claim an installation request.

1. Inspect the configured marketplaces with `codex plugin marketplace list --json` and require the marketplace named `cogentstack` to use `https://github.com/cogentspec/cogentspec-marketplace.git`.
2. Run `codex plugin marketplace upgrade cogentstack --json` once. Do not replace the marketplace with an unverified download or a different source.
3. Resolve the refreshed marketplace root from a new `codex plugin marketplace list --json` result. Require the checked-in file `.agents/plugins/install-cogentspec.ps1` beneath that exact root.
4. Run that verified installer exactly once with `-UpdateOnly`, `-MarketplacePrepared`, and `-InstallerTimeoutSeconds 120`. Do not pass an installation request, login, licence key, activation code, Desktop credential, or legal confirmation.
5. Require one compact result with `protocol: trusted-marketplace-update-v1`, `status: updated`, `credentialPreserved: true`, `previousPackageReplaced: true`, `packageRuntimeCleared: true`, `workerStateCleared: true`, `continueCurrentTask: true`, `claimAttempted: false`, and `accountRequestConsumed: false`. Report the installed version.
6. Continue in the current ChatGPT or Codex task. Treat `refreshedPluginPath` from the verified installer result as the only current package root, invoke the refreshed project-context and Bridge helpers beneath that root, and complete the original `$cogentspec` request. Never invoke a helper from the pre-update package and never ask the user to start a new task.

If marketplace inspection, refresh, package verification, or installation fails, report the exact failed stage and reason. Do not fall back to the first-install protocol and do not ask the user for an account-bound reference.
