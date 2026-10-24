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

export function verifiedReceipt(value) {
  return value?.protocol === 'cogentspec-workspace-beacon-start-v1' && value.status === 'connected'
    && value.workspaceConnected === true && value.acknowledgementVerified === true
    && value.browserReused === true && value.browserOpened === false
    && value.browserHandoff === 'authenticated-workspace-reuse' && value.surface === 'qwen-web' && value.experience === 'web';
}
