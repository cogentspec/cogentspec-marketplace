# CogentSpec Claude update protocol v1

Use this protocol only to update an existing CogentSpec plugin in Claude Code Desktop. It refreshes the public package and leaves the account-bound Desktop Bridge credential protected for the current Windows user.

1. Run `claude plugin marketplace list --json` and require the marketplace named `cogentstack` to resolve to the official `cogentspec/cogentspec-marketplace` GitHub repository.
2. Run `claude plugin list --json`, find the installed `cogentspec@cogentstack` plugin, and preserve its current installation scope. If only the compatibility plugin `cogentstack@cogentstack` is installed, update that plugin in its current scope instead.
3. Run `claude plugin marketplace update cogentstack` once.
4. Run `claude plugin update <the installed plugin id> --scope <its current scope>` once.
5. Run `claude plugin list --json` again. Require the plugin to remain installed and enabled at the version published by the refreshed marketplace.
6. Report the installed version and tell the user to start a new Claude Code conversation before invoking `$cogentspec` again.

Do not remove and reinstall the plugin. Do not request a login, licence key, activation code, legal confirmation, installation reference, or Desktop credential. If inspection, refresh, update, or verification fails, report the exact command stage and reason.
