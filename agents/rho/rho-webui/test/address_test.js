import { test, expect } from "bun:test";
import { formatAddress, panelPath, parseAddress } from "../webui/kernel/address.js";

const empty = { panel: null, conversation: null, workspace: null, plugin: null, item: null };

test("every address shape round-trips through its path, and a path that fits none is the hero", () => {
  const shapes = [
    ["/", {}],
    ["/workspaces/w-1", { workspace: "w-1" }],
    ["/workspaces/w-1/conversations/c-1", { workspace: "w-1", conversation: "c-1" }],
    ["/conversations/c-1", { conversation: "c-1" }],
    ["/plugins", { panel: "plugins" }],
    ["/plugins/rho.ingress_telegram", { panel: "plugins", plugin: "rho.ingress_telegram" }],
    ["/panels/bots", { panel: "bots" }],
    ["/panels/bots/u-reviewer", { panel: "bots", item: "u-reviewer" }],
  ];
  for (const [path, address] of shapes) {
    expect(parseAddress(path)).toEqual({ ...empty, ...address });
    expect(formatAddress(address)).toBe(path);
  }
  for (const path of ["/auth/callback", "/workspaces", "/workspaces/w-1/conversations", "/plugins/a/b", "/panels", "/panels/bots/a/b", "/nope/at/all"]) {
    expect(parseAddress(path)).toEqual(empty);
  }
});

test("segments are encoded on the way out and decoded on the way in; the conversation panel is the hero", () => {
  expect(formatAddress({ panel: "plugins", plugin: "personal.notes/dev" })).toBe("/plugins/personal.notes%2Fdev");
  expect(parseAddress("/plugins/personal.notes%2Fdev").plugin).toBe("personal.notes/dev");
  expect(parseAddress("/plugins/%E0%A4%A").plugin).toBe("%E0%A4%A");
  expect(formatAddress({ panel: "conversation", workspace: "w-1" })).toBe("/workspaces/w-1");
  expect(panelPath("plugins")).toBe("/plugins");
  expect(panelPath("t3")).toBe("/panels/t3");
  // A panel address names only the panel.
  expect(formatAddress({ panel: "t3", conversation: "c-1", workspace: "w-1" })).toBe("/panels/t3");
});
