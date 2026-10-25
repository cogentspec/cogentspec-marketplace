# Bridge change requirements

- Read `docs/bridge-firewall.md` before changing Bridge commands or packaging.
- Keep the type/provider matrix explicit. Do not substitute commands, add
  cross-command orchestration imports, or put connection behavior in a generic
  helper. Existing shared runtime is a frozen, explicitly classified dependency.
- Run the firewall before editing and after verification. Never automatically
  refresh locks during a build. An explicit adoption must name the exact affected
  command set and explain the change; this is change recording, not a new user
  approval requirement.
- Run the declared automated contracts for all affected commands. Do not equate
  source checks, worker readiness, fixtures or skipped tests with a live pass.
- Before publishing, run the protected release gate against the previous
  published revision with current integration and actual live observations.
  Missing evidence blocks publication. Preserve earlier tags.
- Keep normal commands quiet: no new Codex confirmation card, duplicate approval,
  tab opening, or automatic ownership approval. Use isolated fixtures for tests;
  preserve the user's live session during implementation.
- Candidate distribution is a separate pre-production step: use the candidate
  gate before uploading its exact committed source to the fixed candidate ref.
  Keep stable branches, catalogues and release tags unchanged until releaseGate
  passes. A candidate receipt never counts as live verification or promotion.
