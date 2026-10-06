export function isWorkspace(url) {
  try {
    const value = new URL(url);
    return value.protocol === "https:" && ["cogentspec.com", "cogentspec.app"].includes(value.hostname)
      && ["/stack", "/workspace"].some(path => value.pathname === path || value.pathname.startsWith(path + "/"));
  } catch { return false; }
}

// No titles, content, URL query parameters or unrelated tab identities leave the extension.
export function snapshot(tabs, focusedWindowId) {
  const workspaceTabs = tabs.filter(tab => isWorkspace(tab.url || tab.pendingUrl))
    .map(tab => ({id: tab.id, windowId: tab.windowId, active: tab.active === true}));
  const state = !workspaceTabs.length ? "closed"
    : focusedWindowId === -1 ? "blurred"
    : workspaceTabs.some(tab => tab.windowId === focusedWindowId && tab.active) ? "active" : "hidden";
  return {state, workspaceTabs};
}
