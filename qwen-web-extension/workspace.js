(() => {
  const contextPattern = /^ctx-[a-f0-9]{64}$/;
  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (sender.id !== chrome.runtime.id || message?.protocol !== 'cogentspec-qwen-web-page-v1') return false;
    const url = new URL(location.href);
    if (url.origin !== 'https://cogentspec.app' || url.pathname !== '/stack'
      || url.searchParams.get('surface') !== 'qwen-web' || url.searchParams.get('experience') !== 'web') return false;
    if (message.operation === 'prepare') {
      reply({approved:window.confirm('Connect this Qwen Web work area? The page will reload. Save any unfinished work before continuing.')});
      return false;
    }
    if (message.operation !== 'verify' || !contextPattern.test(message.contextKey)
      || url.searchParams.get('context') !== message.contextKey || url.hash) return false;
    void (async () => {
      try {
        const led = document.querySelector('[role="status"][aria-label="Bridge connected"][data-state="connected"]');
        if (!led) { reply({connected:false}); return; }
        const response = await fetch('/api/project-requests?surface=qwen-web&context='+encodeURIComponent(message.contextKey),
          {credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(5000)});
        const body = response.ok ? await response.json() : null;
        reply({connected:response.ok && Array.isArray(body?.requests)});
      } catch { reply({connected:false}); }
    })();
    return true;
  });
})();
