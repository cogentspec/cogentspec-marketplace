import { collectProjectPreview } from './project-preview-build.mjs';

// This helper receives the protected credential only on stdin. Neither files,
// local paths nor credentials are written to worker logs or its result.
let input = ''; for await (const chunk of process.stdin) { input += chunk; if (input.length > 16384) throw Error('Invalid upload request.'); }
try {
  const job = JSON.parse(input), context = job.context;
  if (!/^ctx-[a-f0-9]{64}$/.test(context) || !job.token || !job.upload?.id) throw Error('Invalid upload request.');
  let build;
  try { build = await collectProjectPreview(job.upload); }
  catch (error) { build = { error: ['identity_mismatch','unsafe_build','build_missing','build_too_large','build_changed'].includes(error.code) ? error.code : 'unavailable' }; }
  const response = await fetch('https://cogentspec.com/api/plugin/project-preview-uploads?context=' + encodeURIComponent(context), {
    method: 'POST', headers: { authorization: 'Bearer ' + job.token, 'content-type': 'application/json' },
    body: JSON.stringify({ ...build, id: job.upload.id, projectId: job.upload.projectId }), redirect: 'error', signal: AbortSignal.timeout(150_000),
  });
  // No automatic retry: a lost response may follow a successful upload.
  console.log(JSON.stringify({ received: response.ok }));
} catch { console.log(JSON.stringify({ received: false })); }
