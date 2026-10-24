(() => {
  const editorSelector = '#chat-input, textarea, [contenteditable="true"][role="textbox"], div[contenteditable="true"]';
  let lastEditor, busy = false;
  function editor(element) { return element instanceof Element ? element.closest(editorSelector) : null; }
  function exactCommand(element) {
    return element && !element.closest('[hidden],[aria-hidden="true"]') && element.getClientRects().length
      && (element.value ?? element.textContent ?? '').trim() === '$qwenweb';
  }
  function show(message, duration = 10000) {
    const host = document.createElement('div');
    const root = host.attachShadow({mode:'closed'}), label = document.createElement('div');
    label.setAttribute('role','status'); label.textContent = message;
    label.style.cssText = 'position:fixed;bottom:20px;right:16px;max-width:340px;padding:12px 16px;border:1px solid #7cb9ad;border-radius:9px;background:white;color:#16384a;font:14px/1.5 system-ui;box-shadow:0 3px 18px #0002;z-index:2147483647';
    root.append(label); document.documentElement.append(host);
    const timer = setTimeout(() => host.remove(),duration);
    return () => {clearTimeout(timer);host.remove();};
  }
  async function connect() {
    if (busy) return;
    busy = true;
    const close = show('Connecting CogentSpec Bridge…',60000);
    try {
      // The first sent message creates Qwen's conversation URL. Never invent a
      // task from a browser/profile directory or read the conversation body.
      const deadline = Date.now()+8000;
      while (location.pathname === '/' && Date.now()<deadline) await new Promise(resolve=>setTimeout(resolve,100));
      const result = await chrome.runtime.sendMessage({protocol:'cogentspec-qwen-web-command-v1',command:'$qwenweb',requestId:crypto.randomUUID()});
      close(); show(result?.message || 'Bridge connection could not be verified.',result?.connected ? 3000 : 10000);
    } catch {close();show('The CogentSpec Qwen Web connector is unavailable.');}
    finally {busy=false;}
  }
  document.addEventListener('focusin', event => { const found=editor(event.target);if(found)lastEditor=found; },true);
  document.addEventListener('keydown', event => {
    if (!event.isTrusted || event.isComposing || event.key !== 'Enter' || event.shiftKey || event.ctrlKey || event.altKey || event.metaKey) return;
    if (exactCommand(editor(event.target))) void connect();
  },true);
  document.addEventListener('submit', event => {
    if (event.isTrusted && event.target instanceof Element && event.target.contains(lastEditor) && exactCommand(lastEditor)) void connect();
  },true);
  document.addEventListener('click', event => {
    if (!event.isTrusted || !(event.target instanceof Element)) return;
    const button=event.target.closest('button,[role="button"]');
    if (!button || button.disabled) return;
    const name=(button.getAttribute('aria-label') || button.getAttribute('title') || button.textContent || '').trim();
    const sends = button.matches('#send-message-button,[data-testid="send-button"],button[type="submit"]') || /^(?:send(?: message)?|发送)$/i.test(name);
    if (sends && exactCommand(lastEditor || document.querySelector('#chat-input'))) void connect();
  },true);
  // Do not prevent sending, inspect replies, navigate, open tabs, or accept
  // window.postMessage requests. Synthetic page events cannot start a command.
})();
