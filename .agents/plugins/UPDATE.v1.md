# CogentSpec update protocol v1

Use this protocol only to update an existing CogentSpec plugin installation. It refreshes the public package and preserves the account-bound Desktop Bridge credential already protected for the current Windows user. It does not create or claim an installation request.

1. Inspect the configured marketplaces with `codex plugin marketplace list --json` and require the marketplace named `cogentstack` to use `https://github.com/cogentspec/cogentspec-marketplace.git`.
2. Run `codex plugin marketplace upgrade cogentstack --json` once. Do not replace the marketplace with an unverified download or a different source.
3. Resolve the refreshed marketplace root from a new `codex plugin marketplace list --json` result. Require the checked-in file `.agents/plugins/install-cogentspec.ps1` beneath that exact root.
4. Run that verified installer exactly once with `-UpdateOnly`, `-MarketplacePrepared`, and `-InstallerTimeoutSeconds 120`. Do not pass an installation request, login, licence key, activation code, Desktop credential, or legal confirmation.
5. Require one compact result with `protocol: trusted-marketplace-update-v1`, `status: updated`, `credentialPreserved: true`, `claimAttempted: false`, and `accountRequestConsumed: false`. Report the installed version.
6. Tell the user to start a new ChatGPT or Codex task before invoking `$cogentspec`, because the task which performed the update may still have the earlier plugin instructions loaded.

If marketplace inspection, refresh, package verification, or installation fails, report the exact failed stage and reason. Do not fall back to the first-install protocol and do not ask the user for an account-bound reference.
