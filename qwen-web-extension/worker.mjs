import { commandBinding, verifiedHandoff, workspaceTab } from './policy.mjs';
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
      const url = verifiedHandoff(result, binding);
      if (!url) throw new Error('unverified_handoff');
      const tabs = (await chrome.tabs.query({url:'https://cogentspec.app/stack*'}))
        .filter(tab => workspaceTab(tab.url) && tab.incognito !== true);
      if (tabs.length !== 1) {
        reply({connected:false,message:'Open exactly one intended CogentSpec Qwen Web work area before sending $qwenweb.'}); return;
      }
      const tab = tabs[0];
      const consent = await chrome.tabs.sendMessage(tab.id,{protocol:'cogentspec-qwen-web-page-v1',operation:'prepare'});
      if (consent?.approved !== true) { reply({connected:false,message:'The Web handoff was cancelled. Your work area was not changed.'}); return; }
      await chrome.tabs.update(tab.id,{url});
      let connected = false;
      for (let attempt = 0; attempt < 40; attempt++) {
        await new Promise(resolve => setTimeout(resolve,500));
        try {
          const page = await chrome.tabs.sendMessage(tab.id,{protocol:'cogentspec-qwen-web-page-v1',operation:'verify',contextKey:binding.contextKey});
          if (page?.connected === true) { connected = true; break; }
        } catch { /* Navigation may still be loading its content script. */ }
      }
      reply({connected,message:connected ? 'Bridge connected.' : 'The authenticated work area opened, but its connection could not be verified.'});
    } catch {
      reply({connected:false,message:'The CogentSpec Qwen Web connector is unavailable. Complete its local connector setup, then try again.'});
    } finally { if (context) pending.delete(context); }
  })();
  return true;
});
