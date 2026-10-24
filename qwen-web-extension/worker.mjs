import { commandBinding, verifiedReceipt } from './policy.mjs';
const pending = new Set();
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.protocol !== 'cogentspec-qwen-web-command-v1') return false;
  void (async () => {
    let context;
    try {
      const binding = await commandBinding(message, sender, chrome.runtime.id);
      if (!binding) { reply({connected:false,message:'Send $qwenweb from an existing Qwen conversation.'}); return; }
      context = binding.contextKey;
      if (pending.has(context)) { reply({connected:false,message:'A Bridge connection is already in progress.'}); context = undefined; return; }
      pending.add(context);
      const result = await chrome.runtime.sendNativeMessage('com.cogentspec.qwen_web', binding);
      const connected = result?.requestId === binding.requestId && verifiedReceipt(result);
      reply({connected,message:connected ? 'Bridge connected.' : 'Bridge did not connect. Select Initiate Bridge in your existing CogentSpec Qwen Web work area, then send $qwenweb again.'});
    } catch {
      reply({connected:false,message:'The CogentSpec Qwen Web connector is unavailable. Complete its local connector setup, then try again.'});
    } finally { if (context) pending.delete(context); }
  })();
  return true;
});
