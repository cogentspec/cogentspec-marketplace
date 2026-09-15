import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const fixtureRoot = await mkdtemp(join(tmpdir(), "cogentspec-update-check-"));
const pluginRoot = join(fixtureRoot, "cogentspec");
const scriptDirectory = join(pluginRoot, "skills", "cogentspec", "scripts");
let invalidResponse = false;

const server = createServer((request, response) => {
  const url = new URL(request.url ?? "/", "http://127.0.0.1");
  if (url.pathname !== "/api/plugin-version") {
    response.writeHead(404).end();
    return;
  }
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify(invalidResponse ? { protocol: "unexpected" } : {
    protocol: "cogentspec-plugin-release-v1",
    surface: "chatgpt",
    pluginId: "cogentspec",
    availableVersion: "0.6.6",
    updateProtocolUrl: "https://github.com/cogentspec/cogentspec-marketplace/blob/main/.agents/plugins/UPDATE.v1.md",
  }));
});

async function runCheck(scriptPath, serviceUrl) {
  return await new Promise((resolve, reject) => {
    const child = spawn("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath], {
      windowsHide: true,
      env: { ...process.env, COGENTSPEC_UPDATE_TEST_MODE: "1", COGENTSPEC_UPDATE_TEST_SERVICE_URL: serviceUrl },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(`Update check exited ${code}: ${stderr || stdout}`));
      else resolve(JSON.parse(stdout.trim().split(/\r?\n/).at(-1)));
    });
  });
}

try {
  await mkdir(scriptDirectory, { recursive: true });
  const sourceScript = join(repositoryRoot, "plugins", "cogentspec", "skills", "cogentspec", "scripts", "check-cogentspec-update.ps1");
  const fixtureScript = join(scriptDirectory, "check-cogentspec-update.ps1");
  await cp(sourceScript, fixtureScript);
  const manifestPath = join(pluginRoot, ".codex-plugin", "plugin.json");
  await mkdir(dirname(manifestPath), { recursive: true });
  await writeFile(manifestPath, JSON.stringify({ name: "cogentspec", version: "0.6.5" }));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.equal(typeof address, "object");
  const serviceUrl = `http://127.0.0.1:${address.port}`;

  const available = await runCheck(fixtureScript, serviceUrl);
  assert.equal(available.protocol, "cogentspec-update-check-v1");
  assert.equal(available.status, "update_available");
  assert.equal(available.installedVersion, "0.6.5");
  assert.equal(available.availableVersion, "0.6.6");
  assert.equal(available.updateRequired, true);

  await writeFile(manifestPath, JSON.stringify({ name: "cogentspec", version: "0.6.6" }));
  const current = await runCheck(fixtureScript, serviceUrl);
  assert.equal(current.status, "current");
  assert.equal(current.updateRequired, false);

  invalidResponse = true;
  const unavailable = await runCheck(fixtureScript, serviceUrl);
  assert.equal(unavailable.status, "check_unavailable");
  assert.equal(unavailable.updateRequired, false);
  assert.match(unavailable.exactReason, /invalid update description/i);

  console.log(JSON.stringify({
    status: "valid",
    updateAvailableDetected: true,
    currentVersionDetected: true,
    invalidReleaseRejected: true,
    credentialRead: false,
  }));
} finally {
  await new Promise((resolve) => server.close(resolve));
  await rm(fixtureRoot, { recursive: true, force: true });
}
