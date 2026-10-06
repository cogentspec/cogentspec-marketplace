import assert from "node:assert/strict";
import test from "node:test";
import {isWorkspace, snapshot} from "./policy.mjs";
const workspace = (id, active = true, windowId = 1) => ({id, windowId, active, url: "https://cogentspec.com/stack?secret=not-transmitted"});
test("only exact HTTPS workspace origins and routes qualify", () => {
  for (const url of ["https://cogentspec.com/stack", "https://cogentspec.app/workspace", "https://cogentspec.app/stack/x"]) assert.equal(isWorkspace(url), true);
  for (const url of ["http://cogentspec.com/stack", "https://cogentspec.com.evil/stack", "https://cogentspec.com/", "https://cogentspec.com/stack-evil"]) assert.equal(isWorkspace(url), false);
});
test("tab switch, app switch and return are distinct", () => {
  assert.equal(snapshot([workspace(1)], 1).state, "active");
  assert.equal(snapshot([workspace(1, false)], 1).state, "hidden");
  assert.equal(snapshot([workspace(1)], -1).state, "blurred");
  assert.equal(snapshot([workspace(1)], 1).state, "active");
});
test("last tab removal is closed; another workspace remains authoritative", () => {
  assert.equal(snapshot([], 1).state, "closed");
  assert.equal(snapshot([workspace(2, false)], 1).state, "hidden");
  assert.equal(snapshot([workspace(2, true, 2)], 2).state, "active");
});
test("refresh keeps browser tab identity; BFCache navigation is queried, not guessed", () => {
  assert.deepEqual(snapshot([workspace(1)], 1), snapshot([{...workspace(1), status: "loading"}], 1));
  assert.equal(snapshot([{id: 1, windowId: 1, active: true, pendingUrl: "https://cogentspec.app/stack"}], 1).state, "active");
});
test("snapshot contains no URL, query, title, content or unrelated tab ID", () => {
  const result = snapshot([workspace(1), {id: 999, url: "https://private.example/", title: "Private"}], 1);
  assert.deepEqual(result, {state: "active", workspaceTabs: [{id: 1, windowId: 1, active: true}]});
});
