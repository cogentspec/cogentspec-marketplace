# CogentSpec Claude update protocol v1

Use this protocol only to update an existing CogentSpec plugin in Claude Code Desktop. It refreshes the public package and leaves the account-bound Desktop Bridge credential protected for the current Windows user.

1. Run `claude plugin marketplace list --json` and require the marketplace named `cogentstack` to resolve to the official `cogentspec/cogentspec-marketplace` GitHub repository.
2. Run `claude plugin list --json`, find the installed `cogentspec@cogentstack` plugin, and preserve its current installation scope. If only the compatibility plugin `cogentstack@cogentstack` is installed, update that plugin in its current scope instead.
3. Run `claude plugin marketplace update cogentstack` once.
4. Run `claude plugin update <the installed plugin id> --scope <its current scope>` once.
5. Run `claude plugin list --json` again. Require the plugin to remain installed and enabled at the version published by the refreshed marketplace.
6. From the refreshed plugin root, run `skills\cogentspec\scripts\reset-cogentspec-update.ps1` for `cogentspec@cogentstack`, or `skills\cogentstack\scripts\reset-cogentspec-update.ps1` for the compatibility plugin. Require `status: reset`, `packageRuntimeCleared: true`, `workerStateCleared: true`, and `credentialPreserved: true`.
7. Continue in the current Claude Code conversation using only the refreshed plugin root. Resolve the current project and start the Bridge to complete the original `$cogentspec` request. Never invoke a helper from the pre-update package and never ask the user to start a new conversation.

Do not remove and reinstall the plugin. Do not request a login, licence key, activation code, legal confirmation, installation reference, or Desktop credential. If inspection, refresh, update, or verification fails, report the exact command stage and reason.
