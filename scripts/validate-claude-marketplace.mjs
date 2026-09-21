import { spawnSync } from "node:child_process";
import { readdir, readFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const marketplacePath = join(repositoryRoot, ".claude-plugin", "marketplace.json");
const marketplace = JSON.parse(await readFile(marketplacePath, "utf8"));
const updateInstructions = await readFile(join(repositoryRoot, ".agents", "plugins", "UPDATE.CLAUDE.v1.md"), "utf8");
const pluginEntry = marketplace.plugins?.find((candidate) => candidate.name === "cogentspec");
const compatibilityEntry = marketplace.plugins?.find((candidate) => candidate.name === "cogentstack");

const fail = (message) => {
  throw new Error(`Claude marketplace validation failed: ${message}`);
};
const normalized = (value) => value.replaceAll("\r\n", "\n").trimEnd();

for (const marker of [
  "CogentSpec Claude update protocol v1",
  "claude plugin marketplace update cogentstack",
  "claude plugin update <the installed plugin id> --scope <its current scope>",
  "claude plugin list --json",
  "Do not remove and reinstall the plugin",
  "reset-cogentspec-update.ps1",
  "Continue in the current Claude Code conversation",
  "never ask the user to start a new conversation",
]) {
  if (!updateInstructions.includes(marker)) fail(`Claude update protocol is missing required marker: ${marker}`);
}

if (marketplace.name !== "cogentstack") fail("marketplace name must be cogentstack");
if (!pluginEntry) fail("canonical cogentspec plugin entry is missing");
if (!compatibilityEntry) fail("cogentstack compatibility plugin entry is missing");
if (pluginEntry.source !== "./claude-plugins/cogentspec") fail("canonical plugin source must remain inside the Claude package directory");
if (compatibilityEntry.source !== "./claude-plugins/cogentstack") fail("compatibility plugin source must remain inside the Claude package directory");
if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(pluginEntry.version ?? "")) fail("plugin version must use semantic versioning");

const pluginRoot = resolve(repositoryRoot, pluginEntry.source);
if (relative(repositoryRoot, pluginRoot).startsWith("..")) fail("plugin source escapes the repository");

const manifest = JSON.parse(await readFile(join(pluginRoot, ".claude-plugin", "plugin.json"), "utf8"));
const skill = await readFile(join(pluginRoot, "skills", "cogentspec", "SKILL.md"), "utf8");
const scriptsRoot = join(pluginRoot, "skills", "cogentspec", "scripts");
const codexScriptsRoot = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts");

if (manifest.name !== "cogentspec") fail("canonical plugin manifest name must be cogentspec");
if (manifest.version !== pluginEntry.version) fail("marketplace and plugin versions differ");
if (!normalized(skill).startsWith("---\nname: cogentspec\n")) fail("skill frontmatter is invalid");
for (const marker of [
  "$cogentspec",
  "${CLAUDE_PLUGIN_ROOT}",
  "CogentSpec is a normal web application",
  "start-cogentstack-bridge.ps1",
  "browserOpened: false",
  "create_project",
  "delete_project",
  "preview_project",
  "PROJECT_KNOWLEDGE.md",
  "Qwen Desktop",
]) {
  if (!skill.includes(marker)) fail(`skill is missing required marker: ${marker}`);
}
for (const forbidden of [
  "open-cogentstack-panel.ps1",
  "hide-claude-sidebar.ps1",
  "ensure-cogentstack.ps1",
  "surface=claude-desktop",
  "surface=chatgpt",
  "normal Google Chrome or Microsoft Edge window",
  "placement` set to `right",
  "codex_app__open_in_codex",
]) {
  if (skill.includes(forbidden)) fail(`skill contains retired companion behavior: ${forbidden}`);
}

const requiredScripts = [
  "connect-cogentstack.ps1",
  "create-specification-project.ps1",
  "delete-project.ps1",
  "fulfil-project.ps1",
  "generate-project-preview.ps1",
  "native-command.ps1",
  "prepare-deployment.ps1",
  "project-context.ps1",
  "project-knowledge.ps1",
  "project-preview-readiness.ps1",
  "reset-cogentspec-update.ps1",
  "start-cogentstack-bridge.ps1",
  "watch-cogentstack-bridge.ps1",
];
const actualScripts = (await readdir(scriptsRoot)).filter((name) => name.endsWith(".ps1")).sort();
if (JSON.stringify(actualScripts) !== JSON.stringify([...requiredScripts].sort())) {
  fail(`unexpected script inventory: ${actualScripts.join(", ")}`);
}

for (const name of requiredScripts) {
  const claudeSource = await readFile(join(scriptsRoot, name), "utf8");
  const codexSource = await readFile(join(codexScriptsRoot, name), "utf8");
  if (normalized(claudeSource) !== normalized(codexSource)) {
    fail(`${name} must remain identical to the shared Desktop Bridge implementation`);
  }
}

const syntaxPaths = requiredScripts.map((name) => `'${join(scriptsRoot, name).replaceAll("'", "''")}'`).join(", ");
const syntaxCommand = `& { $failed = $false; foreach ($path in @(${syntaxPaths})) { $tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors); if ($errors.Count -gt 0) { $failed = $true; $errors | ForEach-Object { [Console]::Error.WriteLine(\"$($path): $($_.Message)\") } } }; if ($failed) { exit 1 } }`;
const encodedSyntaxCommand = Buffer.from(syntaxCommand, "utf16le").toString("base64");
const syntaxCheck = spawnSync("cmd.exe", [
  "/d", "/s", "/c", `powershell.exe -NoProfile -EncodedCommand ${encodedSyntaxCommand}`,
], { encoding: "utf8", timeout: 30000 });
if (syntaxCheck.error) fail(`PowerShell syntax validation could not complete: ${syntaxCheck.error.message}`);
if (syntaxCheck.status !== 0) fail(`one or more plugin scripts have invalid PowerShell syntax: ${syntaxCheck.stderr.trim()}`);

const bridge = await readFile(join(scriptsRoot, "start-cogentstack-bridge.ps1"), "utf8");
for (const marker of ["bridge = 'started'", "bridge = 'already_running'", "browserOpened = $false", "bridge-runtime\\$runtimeVersion", "[ValidateSet('chatgpt', 'claude-desktop')]", "surface=$([Uri]::EscapeDataString($Surface))", "-ContextKey $resolvedContext", "-WorkspaceGrant", "-RequestTimeoutSeconds 8", "Get-HostPowerShellExecutable", "launcherElapsedMs", "&open=web&nav=$navigationKey#desktop-web=", "&open=chatgpt&nav=$navigationKey#desktop-chatgpt="]) {
  if (!bridge.includes(marker)) fail(`Desktop Bridge starter is missing required marker: ${marker}`);
}
if (!skill.includes("-Surface claude-desktop")) fail("Claude launcher must identify its desktop surface");
for (const forbidden of ["--app", "--new-window", "SetWindowPos", "SW_MAXIMIZE"]) {
  if (bridge.includes(forbidden)) fail(`Desktop Bridge starter contains browser/window behavior: ${forbidden}`);
}

const watcher = await readFile(join(scriptsRoot, "watch-cogentstack-bridge.ps1"), "utf8");
for (const marker of ["/api/plugin/desktop-actions", "create_project", "delete_project", "preview_project", "[string]$PluginVersion", "pluginVersion=$([Uri]::EscapeDataString($PluginVersion))"]) {
  if (!watcher.includes(marker)) fail(`Desktop Bridge watcher is missing required action marker: ${marker}`);
}

const connector = await readFile(join(scriptsRoot, "connect-cogentstack.ps1"), "utf8");
for (const marker of ["desktop-credential.json", "DataProtectionScope]::CurrentUser", "installationBound = $true", "[int]$RequestTimeoutSeconds = 20", "-TimeoutSec $RequestTimeoutSeconds", "contextKey = $GrantContextKey", "surface = $GrantSurface", "/api/device-authorization/browser-grant"]) {
  if (!connector.includes(marker)) fail(`shared connector is missing required marker: ${marker}`);
}
if (bridge.includes("-File $connectionScript")) fail("Desktop Bridge starter still launches a nested account-check process");
if (connector.includes("exit 0")) fail("shared connector can still terminate its calling launcher process");
for (const forbidden of ["claude-desktop-credential.json", "claude-desktop-authorization.json"]) {
  if (connector.includes(forbidden)) fail(`Claude plugin must use the shared Bridge credential: ${forbidden}`);
}

console.log(JSON.stringify({
  status: "valid",
  marketplace: marketplace.name,
  plugin: manifest.name,
  version: manifest.version,
  surface: "claude-code-desktop",
  architecture: "web-first-desktop-bridge",
  scripts: actualScripts.length,
  sharedScriptParity: true,
  browserInspectionPerformed: false,
}));
