import { readFile, readdir } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const manifestPath = join(repositoryRoot, "desktop", "marketplace.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const installInstructions = await readFile(join(repositoryRoot, ".agents", "plugins", "INSTALL.md"), "utf8");
const versionedInstallInstructions = await readFile(join(repositoryRoot, ".agents", "plugins", "INSTALL.v3.md"), "utf8");
const updateInstructions = await readFile(join(repositoryRoot, ".agents", "plugins", "UPDATE.v1.md"), "utf8");
const boundedInstaller = await readFile(join(repositoryRoot, ".agents", "plugins", "install-cogentspec.ps1"), "utf8");
const sourcePluginPath = join(repositoryRoot, "plugins", "cogentspec");
const compatibilityPluginPath = join(repositoryRoot, "plugins", "cogentstack");
const semver = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const sha256 = /^[a-f0-9]{64}$/;

const fail = (message) => {
  throw new Error(`Desktop marketplace validation failed: ${message}`);
};

if (manifest.schemaVersion !== 1) fail("schemaVersion must be 1");
if (!["CogentStack Desktop", "CogentSpec Desktop"].includes(manifest.application)) fail("application identity is invalid");
if (!semver.test(manifest.latestVersion ?? "")) fail("latestVersion must be semantic versioning");
if (!semver.test(manifest.minimumSupportedVersion ?? "")) fail("minimumSupportedVersion must be semantic versioning");

const expectedTag = `desktop-v${manifest.latestVersion}`;
if (manifest.releaseTag !== expectedTag) fail(`releaseTag must be ${expectedTag}`);
if (manifest.releasePageUrl !== `https://github.com/cogentspec/cogentspec-marketplace/releases/tag/${expectedTag}`) {
  fail("releasePageUrl must use the CogentSpec Git marketplace release");
}
if (!Array.isArray(manifest.releaseNotes) || manifest.releaseNotes.length === 0 || manifest.releaseNotes.some((note) => typeof note !== "string" || !note.trim() || note.length > 240)) {
  fail("releaseNotes must contain concise non-empty entries");
}

const windows = manifest.windows ?? {};
const applicationStem = manifest.application === "CogentStack Desktop" ? "CogentStack" : "CogentSpec";
const expectedFilename = `${applicationStem}-Desktop-${manifest.latestVersion}-x64-setup.exe`;
const expectedInstallerUrl = `https://github.com/cogentspec/cogentspec-marketplace/releases/download/${expectedTag}/${expectedFilename}`;
if (windows.architecture !== "x64") fail("the first Windows release must target x64");
if (windows.installerUrl !== expectedInstallerUrl) fail("installerUrl must be the versioned GitHub Release asset");
if (!sha256.test(windows.installerSha256 ?? "")) fail("installerSha256 must be a lowercase SHA-256 digest");
if (!Number.isSafeInteger(windows.installerSizeBytes) || windows.installerSizeBytes < 1) fail("installerSizeBytes must be a positive integer");
if (typeof windows.authenticodeSigned !== "boolean") fail("authenticodeSigned must be explicit");
if (windows.updaterSignature !== undefined && (
  typeof windows.updaterSignature !== "string"
  || windows.updaterSignature.length < 80
  || windows.updaterSignature.length > 512
  || /[\r\n]/.test(windows.updaterSignature)
)) fail("updaterSignature must contain the Tauri signature file content");
if (windows.requiresUserApproval !== true) fail("Windows installation must retain user approval");
if (windows.automaticLaunch !== false) fail("first installation must not claim to launch automatically");

if (installInstructions.includes("https://raw.githubusercontent.com")) {
  fail("the official Codex bootstrap must not require a shell-level raw installer download");
}
if (installInstructions !== versionedInstallInstructions) {
  fail("INSTALL.md and the versioned INSTALL.v3.md protocol must be identical");
}
for (const requiredInstruction of [
  "trusted-marketplace-v3",
  "current user message",
  "Never recover or reuse a reference from an earlier message",
  "Do not start, estimate, announce, or expire an agent-side installation deadline",
  "codex plugin marketplace list --json",
  "codex plugin marketplace add",
  "codex plugin marketplace upgrade cogentstack",
  "install-cogentspec.ps1",
  "$cogentspec",
  "-MarketplacePrepared",
  "-InstallerTimeoutSeconds 120",
  "status: not_started",
  "installerStarted: false",
  "claimAttempted: false",
  "accountRequestConsumed: false",
  "project-context.ps1",
  "project-knowledge.ps1",
]) {
  if (!installInstructions.includes(requiredInstruction)) fail(`INSTALL.md is missing ${requiredInstruction}`);
}
for (const requiredInstallerMarker of [
  "$protocol = 'trusted-marketplace-v3'",
  "[int]$InstallerTimeoutSeconds = 120",
  "[switch]$MarketplacePrepared",
  "prepared_marketplace_verification",
  "installerStarted = $true",
  "installerTimedOut = $installerTimedOut",
  "failureStage = $stage",
  "nativeCommandsStarted = $nativeCommandsStarted",
  "nativeCommandsCompleted = $nativeCommandsCompleted",
  "completedStages = @($completedStages)",
  "claimAttempted = $claimAttempted",
  "accountRequestConsumed = if ($claimSucceeded)",
  "exactReason = [string]$_.Exception.Message",
  "installerElapsedMs = [int]$timer.ElapsedMilliseconds",
  "The installer is not running from the prepared CogentSpec marketplace.",
  "[switch]$UpdateOnly",
  "trusted-marketplace-update-v1",
  "credentialPreserved = $true",
  "previousPackageReplaced = $true",
  "packageRuntimeCleared = $true",
  "workerStateCleared = $true",
  "continueCurrentTask = $true",
  "refreshedPluginPath = $installedPath",
]) {
  if (!boundedInstaller.includes(requiredInstallerMarker)) fail(`the bounded installer is missing ${requiredInstallerMarker}`);
}
for (const prohibitedMarker of ["$DeadlineSeconds", "exceeded 30 seconds", "marketplace registration repair"]) {
  if (boundedInstaller.includes(prohibitedMarker)) fail(`the v3 bounded installer still contains obsolete orchestration: ${prohibitedMarker}`);
}
if (boundedInstaller.includes("marketplace.marketplaceSource.source")) {
  fail("the bounded installer must verify the registered checkout instead of relying on removed marketplace source metadata");
}

const allowlistBlock = boundedInstaller.match(/\$allowedFiles\s*=\s*@\(([\s\S]*?)\n\s*\)/);
if (!allowlistBlock) fail("the bounded installer public-file allowlist could not be parsed");
const allowedPluginFiles = [...allowlistBlock[1].matchAll(/'([^']+)'/g)].map((match) => match[1]).sort();
const pluginEntries = await readdir(sourcePluginPath, { recursive: true, withFileTypes: true });
const actualPluginFiles = pluginEntries
  .filter((entry) => entry.isFile())
  .map((entry) => relative(sourcePluginPath, join(entry.parentPath, entry.name)).replaceAll("\\", "/"))
  .sort();
if (JSON.stringify(actualPluginFiles) !== JSON.stringify(allowedPluginFiles)) {
  fail("the bounded installer allowlist does not exactly match the public plugin package");
}
for (const requiredUpdateInstruction of [
  "CogentSpec update protocol v1",
  "codex plugin marketplace upgrade cogentstack --json",
  "install-cogentspec.ps1",
  "-UpdateOnly",
  "credentialPreserved: true",
  "previousPackageReplaced: true",
  "packageRuntimeCleared: true",
  "workerStateCleared: true",
  "continueCurrentTask: true",
  "refreshedPluginPath",
  "claimAttempted: false",
  "accountRequestConsumed: false",
  "Continue in the current ChatGPT or Codex task",
  "never ask the user to start a new task",
]) {
  if (!updateInstructions.includes(requiredUpdateInstruction)) fail(`UPDATE.v1.md is missing ${requiredUpdateInstruction}`);
}

const canonicalStarter = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "start-cogentstack-bridge.ps1"), "utf8");
const canonicalUpdateCheck = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "check-cogentspec-update.ps1"), "utf8");
const canonicalConnector = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "connect-cogentstack.ps1"), "utf8");
const canonicalReset = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "reset-cogentspec-update.ps1"), "utf8");
const compatibilityStarter = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "start-cogentstack-bridge.ps1"), "utf8");
const compatibilityUpdateCheck = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "check-cogentspec-update.ps1"), "utf8");
const compatibilityConnector = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "connect-cogentstack.ps1"), "utf8");
const compatibilityReset = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "reset-cogentspec-update.ps1"), "utf8");
for (const marker of ["cogentspec-update-check-v1", "/api/plugin-version", "update_available", "check_unavailable", "UPDATE.v1.md"]) {
  if (!canonicalUpdateCheck.includes(marker)) fail(`the automatic update check is missing marker: ${marker}`);
}
for (const [name, source] of [["starter", canonicalStarter], ["connector", canonicalConnector]]) {
  for (const marker of name === "starter"
    ? ["-ContextKey $resolvedContext", "-WorkspaceGrant", "https://cogentspec.app/stack", "#desktop-web=", "#desktop-chatgpt=", "pluginVersion = $pluginVersion"]
    : ["contextKey = $GrantContextKey", "surface = $GrantSurface", "/api/device-authorization/browser-grant"]) {
    if (!source.includes(marker)) fail(`the Desktop Bridge ${name} is missing bound workspace marker: ${marker}`);
  }
}
const canonicalWatcher = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "watch-cogentstack-bridge.ps1"), "utf8");
for (const marker of ["[string]$PluginId", "[string]$PluginVersion", "pluginVersion=$([Uri]::EscapeDataString($PluginVersion))"]) {
  if (!canonicalWatcher.includes(marker)) fail(`the Desktop Bridge watcher is missing version marker: ${marker}`);
}
for (const marker of ["bridge-runtime", "Stop-Process", "packageRuntimeCleared = $true", "workerStateCleared = $true", "credentialPreserved = $true"]) {
  if (!canonicalReset.includes(marker)) fail(`the update reset helper is missing marker: ${marker}`);
}
const normalizedScript = (value) => value.replaceAll("\r\n", "\n");
if (normalizedScript(canonicalStarter) !== normalizedScript(compatibilityStarter)
  || normalizedScript(canonicalUpdateCheck) !== normalizedScript(compatibilityUpdateCheck)
  || normalizedScript(canonicalConnector) !== normalizedScript(compatibilityConnector)
  || normalizedScript(canonicalReset) !== normalizedScript(compatibilityReset)) {
  fail("the canonical and compatibility Desktop Bridge handoffs differ");
}

const marketplace = JSON.parse(await readFile(join(repositoryRoot, ".agents", "plugins", "marketplace.json"), "utf8"));
const canonicalEntry = marketplace.plugins?.find((entry) => entry.name === "cogentspec");
const compatibilityEntry = marketplace.plugins?.find((entry) => entry.name === "cogentstack");
if (marketplace.name !== "cogentstack") fail("the stable marketplace registration id must remain cogentstack");
if (canonicalEntry?.source?.path !== "./plugins/cogentspec") fail("the canonical CogentSpec plugin entry is missing");
if (compatibilityEntry?.source?.path !== "./plugins/cogentstack") fail("the CogentStack compatibility entry is missing");

console.log(JSON.stringify({
  status: "valid",
  application: manifest.application,
  version: manifest.latestVersion,
  tag: manifest.releaseTag,
  installer: expectedFilename,
  sha256: windows.installerSha256,
  size: windows.installerSizeBytes,
  automaticUpdates: Boolean(windows.updaterSignature),
  automaticLaunch: windows.automaticLaunch,
  installerBootstrap: "trusted-marketplace-v3",
  canonicalPlugin: "cogentspec",
  compatibilityPlugin: "cogentstack",
  pluginFiles: actualPluginFiles.length,
}));
