import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument } from "./support/dom.js";
import { mcpToolPicker } from "../webui/features/settings/mcp_tool_picker.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const REF = { source: "nexus", connection_public_id: "connection-1" };
const CONNECTION = { ref: REF, name: "research", account_label: "Personal", available: true,
  tools: [{ name: "search", description: "Search these notes." }] };
const directory = (changes = {}) => ({ connections: [structuredClone(CONNECTION)],
  loading: false, error: null, managementUrl: "https://nexus.test/settings/mcp_connections", ...changes });
const empty = () => ({ disabled_connections: [], disabled_tools: [] });
const toggle = (root, selector, checked) => {
  const control = root.querySelector(selector);
  control.checked = checked; control.dispatchEvent(new Event("change", { bubbles: true }));
};
const toolRow = (picker, connection = "nexus:connection-1", tool = "search") => picker.element.querySelector(`[data-connection="${connection}"][data-tool="${tool}"]`);
const create = (options = {}) => {
  const picker = mcpToolPicker({ directory: directory(), ...options });
  document.body.append(picker.element); return picker;
};

test("MCP starts enabled and independent connection identities keep same-name tool exclusions separate", () => {
  const secondRef = { source: "executor", executor_public_id: "runner-1", server_key: "research" };
  const picker = create({ directory: directory({ connections: [CONNECTION, { ...CONNECTION, ref: secondRef, account_label: "Local" }] }) });
  expect(picker.read()).toEqual(empty());
  expect(picker.element.querySelector('[name="mcp_agent_public_id"]')).toBeNull();
  expect(picker.element.querySelectorAll('[name="mcp_tool"]').every((row) => row.checked)).toBe(true);
  toggle(toolRow(picker), '[name="mcp_tool"]', false);
  expect(picker.read()).toEqual({ ...empty(), disabled_tools: [{ ...REF, tool_name: "search" }] });
  expect(toolRow(picker, "executor:runner-1:research").querySelector('[name="mcp_tool"]').checked).toBe(true);
  expect(picker.element.querySelector("a").href).toBe("https://nexus.test/settings/mcp_connections");
});

test("connection switches preserve individual exclusions and cover newly discovered tools", () => {
  const picker = create({ value: { ...empty(), disabled_tools: [{ ...REF, tool_name: "search" }] } });
  toggle(picker.element, '[name="mcp_connection"]', false);
  picker.update(directory({ connections: [{ ...CONNECTION, tools: [...CONNECTION.tools, { name: "write" }] }] }));
  expect(picker.element.querySelectorAll('[name="mcp_tool"]').every((row) => !row.checked && row.disabled)).toBe(true);
  expect(picker.read()).toEqual({ disabled_connections: [REF], disabled_tools: [{ ...REF, tool_name: "search" }] });
  toggle(picker.element, '[name="mcp_connection"]', true);
  expect(toolRow(picker).querySelector('[name="mcp_tool"]').checked).toBe(false);
  expect(toolRow(picker, "nexus:connection-1", "write").querySelector('[name="mcp_tool"]').checked).toBe(true);
});

test("refresh keeps disabled missing tools and connections editable while new tools remain enabled", () => {
  const picker = create({ value: { ...empty(), disabled_tools: [{ ...REF, tool_name: "search" }] } });
  picker.update(directory({ connections: [{ ...CONNECTION, tools: [...CONNECTION.tools, { name: "write" }] }] }));
  expect(toolRow(picker, "nexus:connection-1", "write").querySelector('[name="mcp_tool"]').checked).toBe(true);
  picker.update(directory({ connections: [] }));
  expect(toolRow(picker).textContent).toContain("Currently unavailable");
  expect(toolRow(picker).querySelector('[name="mcp_tool"]').disabled).toBe(false);
  toggle(toolRow(picker), '[name="mcp_tool"]', true);
  expect(picker.read()).toEqual(empty());
  expect(toolRow(picker)).toBeNull();
});

test("loading and failed discovery preserve saved connection and tool exclusions", () => {
  const value = { disabled_connections: [REF], disabled_tools: [{ ...REF, tool_name: "search" }] };
  const picker = create({ value });
  picker.update(directory({ connections: [], loading: true }));
  expect(picker.element.textContent).toContain("Loading your MCP connections");
  picker.update(directory({ connections: [], error: "Nexus unavailable" }));
  expect(picker.element.textContent).toContain("Nexus unavailable");
  expect(picker.element.textContent).toContain("Your selection is kept");
  expect(picker.read()).toEqual(value);
  toggle(picker.element, '[name="mcp_connection"]', true);
  expect(picker.read().disabled_connections).toEqual([]);
});

test("ordinary status updates keep focused controls and read results cannot mutate the draft", () => {
  const current = directory();
  const picker = create({ directory: current });
  const control = picker.element.querySelector('[name="mcp_connection"]');
  control.focus(); picker.update({ ...current });
  expect(document.activeElement).toBe(control);
  const value = picker.read(); value.disabled_connections.push(REF);
  expect(picker.read()).toEqual(empty());
});
