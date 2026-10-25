// Explicit command matrix. Execution host and AI provider are separate axes.
// Unsupported cells have no entry and must never fall back to another command.
export const bridgeCommands = Object.freeze([
  Object.freeze({ id: 'snap/gpt', type: 'snap', provider: 'gpt', command: '$gptsnap', surface: 'chatgpt', experience: 'split-screen' }),
  Object.freeze({ id: 'snap/claude', type: 'snap', provider: 'claude', command: '$claudesnap', surface: 'claude-desktop', experience: 'split-screen' }),
  Object.freeze({ id: 'web/gpt', type: 'web', provider: 'gpt', command: '$gptweb', surface: 'chatgpt', experience: 'web' }),
  Object.freeze({ id: 'web/claude', type: 'web', provider: 'claude', command: '$claudeweb', surface: 'claude-desktop', experience: 'web' }),
  Object.freeze({ id: 'web/qwen', type: 'web', provider: 'qwen', command: '$qwenweb', surface: 'qwen-web', experience: 'web' }),
  Object.freeze({ id: 'desk/gpt', type: 'desk', provider: 'gpt', command: '$gptdesk', surface: 'chatgpt', experience: 'desktop-ui' }),
  Object.freeze({ id: 'desk/claude', type: 'desk', provider: 'claude', command: '$claudedesk', surface: 'claude-desktop', experience: 'desktop-ui' }),
  Object.freeze({ id: 'local/qwen', type: 'local', provider: 'qwen', command: '$qwenlocal', surface: 'qwen-local', experience: 'local' }),
]);

// Explicit compatibility contracts, not new matrix cells or inferred fallbacks.
const compatibilityDestinations = Object.freeze([
  Object.freeze({ surface: 'chatgpt', experience: 'popout', command: '$gptpop' }),
  Object.freeze({ surface: 'claude-desktop', experience: 'popout', command: '$claudedesk' }),
]);

export function resolveBridgeCommand(type, provider) {
  return bridgeCommands.find(command => command.type === type && command.provider === provider) || null;
}

export function resolveBridgeDestination(surface, experience) {
  if (surface === 'claude-web') surface = 'claude-desktop';
  if (experience === 'desktop') experience = 'desktop-ui';
  const selected = bridgeCommands.find(command => command.type !== 'local' && command.surface === surface && command.experience === experience)
    || compatibilityDestinations.find(command => command.surface === surface && command.experience === experience);
  return selected ? { surface, experience, command: selected.command } : null;
}
