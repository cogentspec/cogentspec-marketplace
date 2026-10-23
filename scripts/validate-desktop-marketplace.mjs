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
const compatibilityInstaller = await readFile(join(repositoryRoot, ".agents", "plugins", "install-cogentstack.ps1"), "utf8");
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
  "desktopUiBridgeReady = $true",
  "continueCurrentTask = $true",
  "fastUpdatePath = $true",
  "workspaceReadinessSkipped = $true",
  "workspace_readiness_skipped_for_update",
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

let canonicalPluginFileCount = 0;
for (const [name, installer, pluginPath] of [
  ["canonical", boundedInstaller, sourcePluginPath],
  ["compatibility", compatibilityInstaller, compatibilityPluginPath],
]) {
  if (!installer.includes("$workspaceUrl = 'https://cogentspec.app/stack'")) {
    fail(`the ${name} installer must probe the public .app workspace shell, not the signed-in .com portal`);
  }
  for (const guarantee of ["-MaximumRedirection 0", "if ([int]$response.StatusCode -ne 200)", "if ($finalUrl -ne $workspaceUrl)", "project-idea"]) {
    if (!installer.includes(guarantee)) fail(`the ${name} workspace readiness check is missing ${guarantee}`);
  }
  const allowlistBlock = installer.match(/\$allowedFiles\s*=\s*@\(([\s\S]*?)\n\s*\)/);
  if (!allowlistBlock) fail(`the ${name} bounded installer public-file allowlist could not be parsed`);
  const allowedPluginFiles = [...allowlistBlock[1].matchAll(/'([^']+)'/g)].map((match) => match[1]).sort();
  const pluginEntries = await readdir(pluginPath, { recursive: true, withFileTypes: true });
  const actualPluginFiles = pluginEntries
    .filter((entry) => entry.isFile())
    .map((entry) => relative(pluginPath, join(entry.parentPath, entry.name)).replaceAll("\\", "/"))
    .sort();
  if (name === "canonical") canonicalPluginFileCount = actualPluginFiles.length;
  if (JSON.stringify(actualPluginFiles) !== JSON.stringify(allowedPluginFiles)) {
    fail(`the ${name} bounded installer allowlist does not exactly match the public plugin package`);
  }
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
  "fastUpdatePath: true",
  "workspaceReadinessSkipped: true",
  "installerElapsedMs",
  "refreshedPluginPath",
  "claimAttempted: false",
  "accountRequestConsumed: false",
  "Continue in the current ChatGPT or Codex task",
  "never ask the user to start a new task",
]) {
  if (!updateInstructions.includes(requiredUpdateInstruction)) fail(`UPDATE.v1.md is missing ${requiredUpdateInstruction}`);
}

const canonicalStarter = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "start-cogentstack-bridge.ps1"), "utf8");
const canonicalSkill = await readFile(join(sourcePluginPath, "skills", "cogentspec", "SKILL.md"), "utf8");
const canonicalUpdateCheck = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "check-cogentspec-update.ps1"), "utf8");
const canonicalConnector = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "connect-cogentstack.ps1"), "utf8");
const canonicalReset = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "reset-cogentspec-update.ps1"), "utf8");
const canonicalPopoutStarter = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "start-cogentspec-popout-bridge.ps1"), "utf8");
const canonicalPopoutWatcher = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "watch-cogentspec-popout-bridge.ps1"), "utf8");
const canonicalDesktopUiStarter = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "start-cogentspec-desktop-ui-bridge.ps1"), "utf8");
const canonicalDesktopUiWatcher = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "watch-cogentspec-desktop-ui-bridge.ps1"), "utf8");
const canonicalDesktopUiHelper = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "open-chatgpt-desktop-ui.ps1"), "utf8");
const canonicalPopoutNormalizer = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "popout-window-normalizer.ps1"), "utf8");
const canonicalGptWebStarter = await readFile(join(sourcePluginPath, "skills", "gptweb", "scripts", "start-gptweb.ps1"), "utf8");
const compatibilityStarter = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "start-cogentstack-bridge.ps1"), "utf8");
const compatibilitySkill = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "SKILL.md"), "utf8");
const compatibilityUpdateCheck = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "check-cogentspec-update.ps1"), "utf8");
const compatibilityConnector = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "connect-cogentstack.ps1"), "utf8");
const compatibilityReset = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "reset-cogentspec-update.ps1"), "utf8");
const compatibilityPopoutStarter = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "start-cogentspec-popout-bridge.ps1"), "utf8");
const compatibilityPopoutWatcher = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "watch-cogentspec-popout-bridge.ps1"), "utf8");
const compatibilityDesktopUiStarter = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "start-cogentspec-desktop-ui-bridge.ps1"), "utf8");
const compatibilityDesktopUiWatcher = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "watch-cogentspec-desktop-ui-bridge.ps1"), "utf8");
const compatibilityDesktopUiHelper = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "open-chatgpt-desktop-ui.ps1"), "utf8");
const compatibilityPopoutNormalizer = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "popout-window-normalizer.ps1"), "utf8");
const compatibilityGptWebStarter = await readFile(join(compatibilityPluginPath, "skills", "gptweb", "scripts", "start-gptweb.ps1"), "utf8");
const commandContracts = [
  ["gptsnap", "split-screen", "webWorkspaceUrl", "CogentSpec GPT split-screen workspace"],
  ["gptdesk", "desktop-ui", "chatgptWorkspaceUrl", "CogentSpec is connected beside this GPT conversation"],
  ["gptweb", "web", "scripts/start-gptweb.ps1", "CogentSpec GPT web workspace is ready"],
];
for (const pluginPath of [sourcePluginPath, compatibilityPluginPath]) {
  const alias = await readFile(join(pluginPath, "skills/gptpop/SKILL.md"), "utf8");
  if (!alias.includes("../gptsnap/SKILL.md") || alias.includes("-Experience ")) fail("gptpop must delegate to gptsnap without a second launcher");
  for (const [command, experience, destination, confirmation] of commandContracts) {
    const commandRoot = join(pluginPath, "skills", command);
    const commandSkill = await readFile(join(commandRoot, "SKILL.md"), "utf8");
    const commandMetadata = await readFile(join(commandRoot, "agents", "openai.yaml"), "utf8");
    if (command === "gptsnap") {
      if (commandSkill.includes("mcp__codex_app__open_in_codex") || !commandSkill.includes("Never use open_in_codex") || !commandSkill.includes("Do not use browser-control tools")) {
        fail("GPTSnap must delegate opening to its installed command, never agent browser control");
      }
      for (const marker of ["gptsnap-client.mjs", "protected acknowledgement", "registered owning tab"]) {
        if (!commandSkill.includes(marker)) fail(`gptpop external delivery is missing ${marker}`);
      }
    }
    for (const marker of [`name: ${command}`, `-Experience ${experience}`, destination, confirmation]) {
      if (!commandSkill.includes(marker)) fail(`${command} is missing destination marker: ${marker}`);
    }
    for (const marker of [`$${command}`, "allow_implicit_invocation: false"]) {
      if (!commandMetadata.includes(marker)) fail(`${command} metadata is missing explicit-command marker: ${marker}`);
    }
  }
}
if (canonicalPopoutNormalizer !== compatibilityPopoutNormalizer) {
  fail("Desktop Window Normalizer scripts must be identical across GPT packages");
}
for (const [name, normalizer] of [["canonical", canonicalPopoutNormalizer], ["compatibility", compatibilityPopoutNormalizer]]) {
  for (const marker of [
    "verified_gpt_codex_desktop_main_window",
    "single_signed_claude_desktop_main_window",
    "clamped_by_application",
    "SWP_NOSENDCHANGING",
    "SWP_NOACTIVATE",
    "Restore-NormalizerWindows",
    "Invoke-MaintainNormalizedWindows",
    "maintaining_compact_size",
    "Desktop Window Normalizer",
  ]) {
    if (!normalizer.includes(marker)) fail(`${name} Desktop Window Normalizer is missing ${marker}`);
  }
  for (const forbidden of ["SetForegroundWindow", "SendInput", "keybd_event", "mouse_event", "SetWindowLong"]) {
    if (normalizer.includes(forbidden)) fail(`${name} Desktop Window Normalizer must not use ${forbidden}`);
  }
  for (const retired of ["verified_retained_popout", "single_signed_claude_window_candidate", "$title -eq 'Claude'", "$mainChatGptHandles -notcontains"]) {
    if (normalizer.includes(retired)) fail(`${name} Desktop Window Normalizer still contains retired Popout targeting: ${retired}`);
  }
}
for (const pluginPath of [sourcePluginPath, compatibilityPluginPath]) {
  const popoutSkill = await readFile(join(pluginPath, "skills", "gptpop", "SKILL.md"), "utf8");
  for (const marker of [
    "Explicit user-requested Desktop sizing",
    "Window sizing is independent of connection",
    "popout-window-normalizer.ps1",
    "clamped_by_application",
    "never resize the retained GPTPop window",
    "never describe it as a retained Claude Popout",
  ]) {
    if (!popoutSkill.includes(marker)) fail(`gptpop sizing instructions are missing ${marker}`);
  }
}
for (const [name, skill] of [["canonical skill", canonicalSkill], ["compatibility skill", compatibilitySkill]]) {
  for (const marker of [
    "Explicit one-word destination dispatch",
    "before running any Bridge helper",
    "../gptsnap/scripts/start-gptsnap.ps1",
    "-Experience desktop-ui",
    "-Experience web",
    "../gptweb/scripts/start-gptweb.ps1",
    "Treat `invalid_workspace_handoff` as a hard failure",
    "Do not apply the Popout-only `currentConversationConnected` gate",
    "[Open CogentSpec GPT web workspace](<URL>)",
  ]) {
    if (!skill.includes(marker)) fail(`${name} is missing explicit destination dispatch marker: ${marker}`);
  }
}
for (const [name, source] of [["canonical", canonicalGptWebStarter], ["compatibility", compatibilityGptWebStarter]]) {
  for (const marker of [
    "-Experience web",
    "invalid_workspace_handoff",
    "workspace_not_web_destination",
    "workspace_selected_desktop_destination",
    "workspace_url_contract_mismatch",
    "bridge_ready_contract_mismatch",
    "#desktop-web=",
    "^#desktop=",
    "^#desktop-chatgpt=",
    "workspaceUrl = $workspaceUrl",
  ]) {
    if (!source.includes(marker)) fail(`${name} GPTWeb starter is missing fail-closed marker: ${marker}`);
  }
  if (source.includes("chatgptWorkspaceUrl = $chatgptWorkspaceUrl") || source.includes("webWorkspaceUrl = $webWorkspaceUrl")) {
    fail(`${name} GPTWeb starter exposes an alternate private destination`);
  }
}
for (const pluginPath of [sourcePluginPath, compatibilityPluginPath]) {
  const desktopCommandSkill = await readFile(join(pluginPath, "skills", "gptdesk", "SKILL.md"), "utf8");
  if (!desktopCommandSkill.includes('scripts/start-gptdesk.ps1') || !desktopCommandSkill.includes('self-contained')) {
    fail('GPTDesk must use its dedicated one-shot startup entrypoint');
  }
  for (const marker of ['placement: "right"', "native two-column conversation/workspace split", "Omit `threadId` and `tabId`", "ensure-codex-sidebar-hidden.py", "--experience desktop-ui --ensure-split", "layoutVerified: true", "partial Desk result", "AFTER the native open"]) {
    if (!desktopCommandSkill.includes(marker)) fail(`gptdesk is missing native split marker: ${marker}`);
  }
  if (desktopCommandSkill.includes("Omit `threadId`, `tabId`, and `placement`")) {
    fail("gptdesk still opens an unplaced full-view browser tab");
  }
}
const deskStartPath = (pluginPath) => join(pluginPath, 'skills', 'gptdesk', 'scripts', 'start-gptdesk.ps1');
const snapStartPath = pluginPath => join(pluginPath, 'skills', 'gptsnap', 'scripts', 'start-gptsnap.ps1');
const canonicalSnapStart = await readFile(snapStartPath(sourcePluginPath), 'utf8');
const compatibilitySnapStart = await readFile(snapStartPath(compatibilityPluginPath), 'utf8');
if (canonicalSnapStart !== compatibilitySnapStart) fail('GPTSnap startup supervisors must match across GPT packages');
const canonicalSnapClient = await readFile(join(sourcePluginPath, 'skills/gptsnap/scripts/gptsnap-client.mjs'), 'utf8');
const compatibilitySnapClient = await readFile(join(compatibilityPluginPath, 'skills/gptsnap/scripts/gptsnap-client.mjs'), 'utf8');
if (canonicalSnapClient !== compatibilitySnapClient) fail('GPTSnap command clients must match across GPT packages');
for (const pluginPath of [sourcePluginPath, compatibilityPluginPath]) {
  const snapSkill = await readFile(join(pluginPath, 'skills', 'gptsnap', 'SKILL.md'), 'utf8');
  if (!snapSkill.includes('scripts/start-gptsnap.ps1') || !snapSkill.includes('gptsnap-client.mjs')) {
    fail('GPTSnap must use its installed one-shot startup entrypoint');
  }
}
if (/SendInput|open_in_codex|openTabs|claimTab/.test(canonicalSnapStart)
  || /UseShellExecute\s*=\s*\$true|Open-GptSnapBrowser|Start-Process/.test(canonicalSnapStart)
  || !canonicalSnapStart.includes("browserHandoff = 'existing-workspace-only'")) {
  fail('GPTSnap must reconnect only the registered workspace, without opening another work area or agent browser discovery');
}
const canonicalDeskStart = await readFile(deskStartPath(sourcePluginPath), 'utf8');
const compatibilityDeskStart = await readFile(deskStartPath(compatibilityPluginPath), 'utf8');
if (canonicalDeskStart !== compatibilityDeskStart) fail('GPTDesk startup supervisors must match across GPT packages');
for (const marker of ['conversationVerification', 'conversationConnectionReason', 'conversationUserMessage']) {
  if (!canonicalDeskStart.includes(marker)) fail(`GPTDesk startup does not preserve ${marker}`);
}
if (/SendInput|open_in_codex|ensure-codex-sidebar-hidden\.py/.test(canonicalDeskStart)) {
  fail('GPTDesk startup must leave native opening and permitted UI checks to the host');
}
const canonicalSidebarHelper = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "ensure-codex-sidebar-hidden.py"), "utf8");
const compatibilitySidebarHelper = await readFile(join(compatibilityPluginPath, "skills", "cogentstack", "scripts", "ensure-codex-sidebar-hidden.py"), "utf8");
for (const [name, helper] of [["canonical", canonicalSidebarHelper], ["compatibility", compatibilitySidebarHelper]]) {
  for (const marker of ["Hide sidebar", "Show sidebar", "UIA_BUTTON_CONTROL_TYPE_ID", "UIA_INVOKE_PATTERN_ID", "IID_IUIAUTOMATION_INVOKE_PATTERN", '"already_hidden"', '"ambiguous"', '"layout_verified"']) {
    if (!helper.includes(marker)) fail(`${name} Python sidebar helper is missing marker: ${marker}`);
  }
  for (const marker of ["SetForegroundWindow", "focusTargetVerified", "focusRestoreNeeded", "focusRestored", "foreground_changed"]) {
    if (!helper.includes(marker)) fail(`${name} GPTDesk helper is missing temporary focus restoration marker: ${marker}`);
  }
  for (const marker of ["state_checked_shortcut", "target_not_foreground", "shortcut_keys_held", "sidebar_state_changed"]) {
    if (!helper.includes(marker)) fail(`${name} GPTDesk sidebar shortcut is missing its state guard: ${marker}`);
  }
}
if (canonicalSidebarHelper !== compatibilitySidebarHelper) fail("GPTDesk layout helpers must be identical across GPT packages");
for (const marker of ["cogentspec-update-check-v1", "/api/plugin-version", "update_available", "check_unavailable", "UPDATE.v1.md"]) {
  if (!canonicalUpdateCheck.includes(marker)) fail(`the automatic update check is missing marker: ${marker}`);
}
for (const [name, source] of [["canonical skill", canonicalSkill], ["compatibility skill", compatibilitySkill]]) {
  for (const marker of [
    "Keep `webWorkspaceUrl` as a recovery destination",
    "[Open CogentSpec workspace](<URL>)",
    "After either accepted result, do not render `webWorkspaceUrl`",
    "CogentSpec is connected. Continue in the workspace beside this conversation.",
    "the web link is recovery only",
  ]) {
    if (!source.includes(marker)) fail(`${name} is missing native-open response marker: ${marker}`);
  }
  if (source.includes("Open this task’s CogentSpec workspace in web")) {
    fail(`${name} still renders the redundant workspace-in-web link`);
  }
}
for (const [name, source] of [["starter", canonicalStarter], ["connector", canonicalConnector]]) {
  for (const marker of name === "starter"
    ? ["-ContextKey $resolvedContext", "-WorkspaceGrant", "-RequestTimeoutSeconds 6", "Get-HostPowerShellExecutable", "launcherElapsedMs", "https://cogentspec.app/stack", "#desktop-web=", "#desktop-chatgpt=", "pluginVersion = $pluginVersion"]
    : ["[int]$RequestTimeoutSeconds = 20", "-TimeoutSec $RequestTimeoutSeconds", "contextKey = $GrantContextKey", "surface = $GrantSurface", "/api/device-authorization/browser-grant"]) {
    if (!source.includes(marker)) fail(`the Desktop Bridge ${name} is missing bound workspace marker: ${marker}`);
  }
}
for (const marker of ["[ValidateSet('legacy', 'popout', 'desktop-ui', 'web', 'split-screen')]", "$Experience = 'legacy'", "experience=$([Uri]::EscapeDataString($Experience))", "$Experience -in @('popout', 'web', 'split-screen')"]) {
  if (!canonicalStarter.includes(marker)) fail(`the Desktop Bridge starter is missing experience routing marker: ${marker}`);
}
for (const marker of ['Confirm-CurrentConversationConnection', "'desktop_thread_presence'", "'popout_fingerprint'", "'web_destination'", 'conversationConnectionReason']) {
  if (!canonicalStarter.includes(marker)) fail(`the Desktop Bridge starter is missing destination confirmation marker: ${marker}`);
}
if (canonicalStarter.includes("-File $connectionScript")) fail("the Desktop Bridge starter still launches a nested account-check process");
if (canonicalConnector.includes("exit 0")) fail("the Desktop Bridge connector can still terminate its calling launcher process");
for (const [name, connector] of [["canonical", canonicalConnector], ["compatibility", compatibilityConnector]]) {
  if (connector.includes("#desktop=")) fail(`${name} connector still emits the legacy context-free browser route`);
  if (!connector.includes("browserAuthorizationCompleted = $true")) fail(`${name} connector does not separate authorization from workspace launch`);
}
const canonicalWatcher = await readFile(join(sourcePluginPath, "skills", "cogentspec", "scripts", "watch-cogentstack-bridge.ps1"), "utf8");
for (const marker of ["[string]$PluginId", "[string]$PluginVersion", "pluginVersion=$([Uri]::EscapeDataString($PluginVersion))"]) {
  if (!canonicalWatcher.includes(marker)) fail(`the Desktop Bridge watcher is missing version marker: ${marker}`);
}
for (const marker of ["bridge-runtime", "desktop-ui-runtime", "watch-cogentspec-desktop-ui-bridge.ps1", "Stop-Process", "packageRuntimeCleared = $true", "workerStateCleared = $true", "credentialPreserved = $true"]) {
  if (!canonicalReset.includes(marker)) fail(`the update reset helper is missing marker: ${marker}`);
}
for (const marker of ["CogentSpecStandalonePopoutBridge", "popout-runtime", "watch-cogentspec-popout-bridge.ps1", "serverAcknowledged", "while (`$true)", "supervised = $true"]) {
  if (!canonicalPopoutStarter.includes(marker)) fail(`the standalone Popout Bridge starter is missing marker: ${marker}`);
}
for (const marker of ["/api/plugin/desktop-popout-actions", "-UseRetainedChat", "-PasteClipboard", "composerPopulated", "Get-HttpStatusCode", "consecutiveFailures", "MaximumRetryMilliseconds"]) {
  if (!canonicalPopoutWatcher.includes(marker)) fail(`the standalone Popout Bridge watcher is missing marker: ${marker}`);
}
for (const marker of ["CogentSpecDesktopUiBridge", "desktop-ui-runtime", "watch-cogentspec-desktop-ui-bridge.ps1", "serverAcknowledged", "while (`$true)", "supervised = $true"]) {
  if (!canonicalDesktopUiStarter.includes(marker)) fail(`the Desktop UI Bridge starter is missing marker: ${marker}`);
}
for (const marker of ["/api/plugin/desktop-ui-actions", "-StartNewChat", "-PasteClipboard", "newChatStarted", "composerPopulated", "messageSubmitted", "Get-HttpStatusCode", "MaximumRetryMilliseconds"]) {
  if (!canonicalDesktopUiWatcher.includes(marker)) fail(`the Desktop UI Bridge watcher is missing marker: ${marker}`);
}
for (const marker of ["Start-ChatGptDesktop", "Start-NewChat", "'New chat', 'Start new chat'", "publisherVerified = $true", "messageSubmitted = $false", "The new ChatGPT composer unexpectedly contains unsent text."]) {
  if (!canonicalDesktopUiHelper.includes(marker)) fail(`the Desktop UI helper is missing marker: ${marker}`);
}
if (canonicalDesktopUiHelper.includes("VK_RETURN") || canonicalDesktopUiHelper.includes("codex://threads/")) {
  fail("the Desktop UI helper must neither submit the request nor depend on a Codex task deep link");
}
const normalizedScript = (value) => value.replaceAll("\r\n", "\n");
if (normalizedScript(canonicalStarter) !== normalizedScript(compatibilityStarter)
  || normalizedScript(canonicalUpdateCheck) !== normalizedScript(compatibilityUpdateCheck)
  || normalizedScript(canonicalConnector) !== normalizedScript(compatibilityConnector)
  || normalizedScript(canonicalReset) !== normalizedScript(compatibilityReset)
  || normalizedScript(canonicalDesktopUiStarter) !== normalizedScript(compatibilityDesktopUiStarter)
  || normalizedScript(canonicalDesktopUiWatcher) !== normalizedScript(compatibilityDesktopUiWatcher)
  || normalizedScript(canonicalDesktopUiHelper) !== normalizedScript(compatibilityDesktopUiHelper)
  || normalizedScript(canonicalPopoutStarter) !== normalizedScript(compatibilityPopoutStarter)
  || normalizedScript(canonicalPopoutWatcher) !== normalizedScript(compatibilityPopoutWatcher)) {
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
  pluginFiles: canonicalPluginFileCount,
}));
