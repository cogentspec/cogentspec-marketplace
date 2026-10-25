// Opt-in immutable test distribution. This command cannot target stable refs,
// change release tags, install software, or authorize production promotion.
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { candidateGate } from './bridge-firewall.mjs';

export function candidateUploadPlan(receipt, remote, existing = '') {
  const repository = { website: 'cogentspec', marketplace: 'cogentspec-marketplace' }[receipt.component];
  if (!repository || remote !== `https://github.com/cogentspec/${repository}.git`)
    throw new Error('Candidate upload requires the exact official component repository');
  if (receipt.status !== 'candidate-verified' || receipt.liveVerified !== false || receipt.productionPromotionAuthorized !== false
    || !/^[a-f0-9]{40}$/.test(receipt.revision || '') || !/^[a-f0-9]{64}$/.test(receipt.fingerprint || '')
    || receipt.ref !== `refs/heads/codex/candidate/${receipt.component}-${receipt.revision}`)
    throw new Error('Candidate upload requires an exact candidate-only gate receipt');
  if (existing && existing.trim() !== `${receipt.revision}\t${receipt.ref}`)
    throw new Error('Candidate ref already points to different source; it cannot be replaced');
  return { remote, ref: receipt.ref, revision: receipt.revision, alreadyUploaded: Boolean(existing),
    arguments: ['push', '--porcelain', `--force-with-lease=${receipt.ref}:`, 'origin', `${receipt.revision}:${receipt.ref}`] };
}

function main() {
  const root = dirname(dirname(fileURLToPath(import.meta.url)));
  const option = name => { const index = process.argv.indexOf(name); return index < 0 ? undefined : process.argv[index + 1]; };
  const output = option('--output'); if (!output) throw new Error('Candidate receipt output directory is required');
  const git = (args, allowed = [0], input) => {
    const result = spawnSync('git', args, { cwd: root, input, windowsHide: true, maxBuffer: 128 * 1024 * 1024, timeout: 120000 });
    if (!allowed.includes(result.status)) throw new Error('Candidate Git operation failed: ' + args[0]);
    return result;
  };
  const receipt = candidateGate(root, option('--base-ref'), option('--evidence'));
  const remote = git(['remote', 'get-url', 'origin']).stdout.toString().trim();
  // Validate the destination before any network operation.
  candidateUploadPlan(receipt, remote);
  const target = resolve(output); mkdirSync(target, { recursive: true });
  const archive = git(['archive', '--format=tar', receipt.revision]).stdout;
  const archiveSha256 = createHash('sha256').update(archive).digest('hex');
  writeFileSync(resolve(target, `source-${receipt.revision}.tar`), archive);
  // Retain genuine candidate/base Git objects without copying unrelated history.
  // The isolated server marks these two commits as shallow boundaries.
  const tag = git(['rev-parse', '--verify', 'refs/tags/homerun02']).stdout.toString().trim();
  const objects = git(['rev-list', '--objects', '--no-object-names', `${receipt.revision}^{tree}`, `${receipt.base}^{tree}`]).stdout.toString().trim().split('\n');
  const pack = git(['pack-objects', '--stdout'], [0], Buffer.from([...new Set([...objects,receipt.revision,receipt.base,tag])].join('\n')+'\n')).stdout;
  writeFileSync(resolve(target, `objects-${receipt.revision}.pack`), pack);
  const objectPackSha256 = createHash('sha256').update(pack).digest('hex');
  let uploaded = false;
  if (process.argv.includes('--upload')) {
    const existing = git(['ls-remote', '--exit-code', 'origin', receipt.ref], [0, 2]).stdout.toString().trim();
    const plan = candidateUploadPlan(receipt, remote, existing);
    if (!plan.alreadyUploaded) git(plan.arguments);
    const confirmed = git(['ls-remote', '--exit-code', 'origin', receipt.ref]).stdout.toString().trim();
    if (confirmed !== `${receipt.revision}\t${receipt.ref}`) throw new Error('Candidate ref verification failed');
    uploaded = true;
  }
  const result = { ...receipt, uploaded, remote, archiveSha256, archiveBytes: archive.length, objectPackSha256, homerun02TagObject: tag };
  writeFileSync(resolve(target, 'candidate-receipt.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result));
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
