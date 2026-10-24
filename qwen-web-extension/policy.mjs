export function validQwenConversation(raw) {
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && !url.username && !url.password && (!url.port || url.port === '443')
      && (url.hostname === 'qwen.ai' || url.hostname.endsWith('.qwen.ai'))
      && url.pathname !== '/' && !/^\/(?:auth|login|signup|settings)(?:\/|$)/i.test(url.pathname)
      ? `${url.origin}${url.pathname}` : null;
  } catch { return null; }
}

export async function commandBinding(message, sender, extensionId, digest = value => crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))) {
  const conversation = validQwenConversation(sender?.url);
  if (!conversation || sender.id !== extensionId || !sender.documentId
    || !message || Object.keys(message).sort().join(',') !== 'command,protocol,requestId'
    || message.protocol !== 'cogentspec-qwen-web-command-v1' || message.command !== '$qwenweb'
    || !/^[a-f0-9-]{36}$/.test(message.requestId || '')) return null;
  const hash = await digest(`cogentspec:qwen-web:v1:${conversation}`);
  return { protocol: message.protocol, command: '$qwenweb', requestId: message.requestId,
    contextKey: 'ctx-' + [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, '0')).join('') };
}

export function workspaceTab(raw) {
  try {
    const url = new URL(raw);
    return url.origin === 'https://cogentspec.app' && !url.username && !url.password && url.pathname === '/stack'
      && url.searchParams.get('surface') === 'qwen-web' && url.searchParams.get('experience') === 'web';
  } catch { return false; }
}

export function verifiedHandoff(value, binding) {
  if (value?.protocol !== 'cogentspec-qwenweb-navigation-v1' || value.status !== 'ready'
    || value.requestId !== binding.requestId || value.browserOpened !== false || !workspaceTab(value.workspaceUrl)) return null;
  const url = new URL(value.workspaceUrl);
  if ([...url.searchParams].length !== 5 || new Set(url.searchParams.keys()).size !== 5
    || url.searchParams.get('context') !== binding.contextKey || url.searchParams.get('open') !== 'web'
    || !/^[a-f0-9]{32}$/.test(url.searchParams.get('nav') || '')
    || !/^#desktop-web=cgw_[A-Za-z0-9_-]{32,200}$/.test(url.hash)) return null;
  return url.href;
}
