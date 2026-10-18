import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { observable } from "../webui/kernel/observable.js";
import { createNexus } from "../webui/shell/nexus.js";
import { nexusPage, authorizationUrl, gateOf, modelMark, priceLine, providerMark, reasonText } from "../webui/features/nexus/page.js";
import { connectionDefinition, modelDefinition, rateKeys, PROTOCOLS } from "../webui/features/nexus/editors.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const OPENROUTER = { id: "openrouter", display_name: "OpenRouter", credentials: "api_key", enabled: true, lock_version: 3, configured: true,
  material_kind: "api_key", reauthorization_required: false, unavailable_until: null, models: 2 };
const CODEX = { id: "openai-codex", display_name: "OpenAI Codex", credentials: "oauth_tokens", enabled: false, lock_version: null, configured: false,
  material_kind: null, reauthorization_required: false, unavailable_until: null, models: 1 };
const LOCAL = { id: "local", display_name: null, credentials: "none", enabled: false, lock_version: 0, configured: false,
  material_kind: null, reauthorization_required: false, unavailable_until: null, models: 0 };
const KEYED = { id: "keyed", display_name: "Keyed", credentials: "api_key", enabled: false, lock_version: null, configured: false,
  material_kind: null, reauthorization_required: false, unavailable_until: null, models: 0 };
const MODELS = [
  { ref: "openrouter/z-ai/glm-5.3", provider: "openrouter", workload: "text_generation", visible: true, available: true, unavailable_reason: null,
    capabilities: { tool_calls: true, streaming: true }, pricing: { state: "priced", unit: "USD", input_per_mtok: "1.00", output_per_mtok: "2.00" } },
  { ref: "openrouter/hidden-one", provider: "openrouter", workload: "text_generation", visible: false, available: false, unavailable_reason: "model_hidden", capabilities: {}, pricing: { state: "unknown" } },
  { ref: "openrouter/broken", provider: "openrouter", workload: "text_generation", visible: true, available: false, unavailable_reason: "model_unavailable", capabilities: {}, pricing: { state: "unknown" } },
  { ref: "openai-codex/gpt-5", provider: "openai-codex", workload: "text_generation", visible: true, available: false, unavailable_reason: "provider_disabled", capabilities: {}, pricing: { state: "unknown" } },
];
const CONFIGURATIONS = {
  openrouter: { definition: { display_name: "OpenRouter", api_format: "openrouter_chat", base_url: "https://openrouter.ai/api/v1", credentials: "api_key", wire_options: { keep: true } }, source: "catalog",
    models: [{ model: "openrouter/z-ai/glm-5.3", definition: { model_id: "z-ai/glm-5.3", display_name: "GLM 5.3", capabilities: { limits: { input_tokens: 200000 } } }, source: "catalog", removed: false },
      { model: "openrouter/old-one", definition: { model_id: "old-one" }, source: "catalog", removed: true }] },
  "openai-codex": { definition: { api_format: "codex_responses", base_url: "https://chatgpt.com/backend-api", credentials: "codex" }, source: "catalog", models: [] },
  local: { definition: { api_format: "openai_compatible_chat", base_url: "http://127.0.0.1:11434/v1", credentials: "none" }, source: "custom", models: [] },
  keyed: { definition: { api_format: "openai_compatible_chat", base_url: "https://keyed.example/v1", credentials: "api_key" }, source: "override", models: [] },
};

test("the proxy helper asks the daemon for one Nexus request and throws Nexus's own refusal", async () => {
  const calls = [];
  const answers = [{ status: 200, body: { model_providers: [] }, headers: {} }, { status: 409, body: { error: { code: "stale_object", message: "changed" } }, headers: {} }];
  const nexus = createNexus({ call: async (path, options) => { calls.push([path, options]); return answers.shift(); } });

  expect(await nexus.request("/api/v1/admin/model_providers")).toEqual({ model_providers: [] });
  expect(calls[0]).toEqual(["/nexus/request", { method: "POST", body: { path: "/api/v1/admin/model_providers", method: "GET" }, signal: undefined }]);
  let caught = null;
  try { await nexus.request("/api/v1/admin/model_providers/x/lane", { method: "PUT", body: { command: {} }, timeout: 45 }); } catch (error) { caught = error; }
  expect([caught.status, caught.code, caught.message, caught.nexus]).toEqual([409, "stale_object", "changed", true]);
  expect(calls[1][1].body).toEqual({ path: "/api/v1/admin/model_providers/x/lane", method: "PUT", body: { command: {} }, timeout: 45 });
});

test("the proxy forwards upgrade idempotency headers and retains a refusal's receipt reference", async () => {
  const calls = [];
  const nexus = createNexus({ call: async (path, options) => {
    calls.push([path, options]);
    return { status: 409, body: { error: { code: "upgrade_in_progress", message: "Already running", operation_id: "receipt" } } };
  } });
  let caught;
  try { await nexus.request("/api/v1/admin/deployment/upgrades", { method: "POST", headers: { "Idempotency-Key": "key" }, body: { candidate: {} } }); } catch (error) { caught = error; }
  expect(calls[0][1].body.headers).toEqual({ "Idempotency-Key": "key" });
  expect(caught.details.operation_id).toBe("receipt");
});

test("the page's small readers: what a provider or a model says of its state, the authorization page, the gate kinds, reasons, prices", () => {
  // A provider says only what needs attention; its normal states — a saved key, a connection, no credential needed — say nothing.
  expect(providerMark(OPENROUTER)).toBeNull();
  expect(providerMark(KEYED)).toBe("API key needed");
  expect(providerMark(CODEX)).toBe("Not connected");
  expect(providerMark({ ...CODEX, configured: true })).toBeNull();
  expect(providerMark({ ...CODEX, configured: true, reauthorization_required: true })).toBe("Sign-in required");
  expect(providerMark(LOCAL)).toBeNull();
  // A reason every model shares that is the provider's — a credential its models cannot use — is said once, on the provider.
  const unusable = { available: false, unavailable_reason: "credential_unusable" };
  expect(providerMark(OPENROUTER, [unusable, unusable])).toBe("Credential unusable");
  expect(providerMark({ ...OPENROUTER, enabled: false }, [{ available: false, unavailable_reason: "provider_disabled" }])).toBeNull();
  // A model says only its own reason: nothing while available, hidden by its own switch, or held back by its provider.
  expect(modelMark(MODELS[0])).toBeNull();
  expect(modelMark(MODELS[1])).toBeNull();
  expect(modelMark(MODELS[2])).toBe("Marked invalid");
  expect(modelMark(MODELS[3])).toBeNull();
  expect(modelMark({ available: false, unavailable_reason: "reauthorization_required" })).toBeNull();
  expect(modelMark({ available: false, unavailable_reason: "something_new" })).toBe("something_new");
  expect(authorizationUrl("https://nexus.example/admin/model_providers", "openai-codex")).toBe("https://nexus.example/admin/model_providers/openai-codex/authorization");
  expect(authorizationUrl("javascript:alert(1)", "x")).toBeNull();
  expect(gateOf({ code: "human_login_required", status: 403 })).toBe("sign_in");
  expect(gateOf({ code: "administrator_required", status: 403 })).toBe("member");
  expect(gateOf({ code: "model_plane_unavailable", status: 503 })).toBe("unavailable");
  expect(gateOf({ code: "validation_failed", status: 422 })).toBeNull();
  expect(reasonText("missing_credential")).toBe("No credential");
  expect(reasonText("something_new")).toBe("something_new");
  expect(priceLine({ state: "priced", unit: "USD", input_per_mtok: "1.00", output_per_mtok: "2.00" })).toBe("USD 1.00 input / 2.00 output per 1M tokens");
  expect(priceLine({ state: "priced", unit: "USD", output_per_mtok: "1.20" })).toBe("Estimated usage cost in USD");
  expect(priceLine({ state: "priced", unit: "USD" })).toBe("Estimated usage cost in USD");
  expect(priceLine({ state: "unknown" })).toBeNull();
});

test("the editors write the declaration Nexus's forms write: visible fields over the rest, blanks leaving", () => {
  const existing = { display_name: "Old", api_format: "openrouter_chat", base_url: "https://old", credentials: "api_key", concurrency_limit: 4, wire_options: { keep: true } };
  expect(connectionDefinition(existing, { display_name: " New ", api_format: "openai_responses", base_url: "https://new/v1", credentials: "none", concurrency_limit: "" }))
    .toEqual({ display_name: "New", api_format: "openai_responses", base_url: "https://new/v1", credentials: "none", wire_options: { keep: true } });
  expect(connectionDefinition(null, { display_name: "", api_format: "openai_compatible_chat", base_url: "http://x/v1", credentials: "api_key", concurrency_limit: " 8 " }))
    .toEqual({ api_format: "openai_compatible_chat", base_url: "http://x/v1", credentials: "api_key", concurrency_limit: 8 });
  const model = { model_id: "a", capabilities: { limits: { input_tokens: 1000, output_tokens: 10 }, tool_calls: true, reasoning: { kind: "x" } }, pricing: { account_unit: "USD", schedule: { kind: "catalog_only", rates: { input_per_mtok: "1" }, note: "n" } }, wire_options: { keep: true } };
  expect(modelDefinition(model, { model_id: " b ", display_name: "B", input_tokens: "2000", output_tokens: "", combined_input_output_tokens: "", effective_input_tokens: "",
    tool_calls: "false", streaming: "", pricing_mode: "preserve", pricing_unit: "", rate_keys: ["input_per_mtok", "output_per_mtok"] }))
    .toEqual({ model_id: "b", display_name: "B", capabilities: { limits: { input_tokens: 2000 }, tool_calls: false, reasoning: { kind: "x" } },
      pricing: { account_unit: "USD", schedule: { kind: "catalog_only", rates: { input_per_mtok: "1" }, note: "n" } }, wire_options: { keep: true } });
  expect(modelDefinition(model, { model_id: "b", display_name: "", input_tokens: "", output_tokens: "", combined_input_output_tokens: "", effective_input_tokens: "",
    tool_calls: "", streaming: "", pricing_mode: "custom", pricing_unit: " USD ", input_per_mtok: "3", output_per_mtok: "", rate_keys: ["input_per_mtok", "output_per_mtok"] }))
    .toEqual({ model_id: "b", capabilities: { reasoning: { kind: "x" } }, pricing: { account_unit: "USD", schedule: { note: "n", kind: "catalog_only", rates: { input_per_mtok: "3" } } }, wire_options: { keep: true } });
  expect(modelDefinition(null, { model_id: "c", display_name: "", input_tokens: "", output_tokens: "", combined_input_output_tokens: "", effective_input_tokens: "",
    tool_calls: "", streaming: "", pricing_mode: "none", pricing_unit: "", rate_keys: [] })).toEqual({ model_id: "c" });
  expect(rateKeys("deepseek_responses")).toEqual(["input_cache_hit_per_mtok", "input_cache_miss_per_mtok", "output_per_mtok"]);
  expect(rateKeys("openai_compatible_chat")).toEqual(["input_per_mtok", "output_per_mtok", "cached_input_per_mtok"]);
  expect(rateKeys("openai_images")).toEqual([]);
  expect(PROTOCOLS).not.toContain("codex_responses");
});

function harness({ providers = [OPENROUTER, CODEX, LOCAL, KEYED], models = MODELS, configurations = CONFIGURATIONS, fail = null, writeError = null } = {}) {
  const requests = [];
  const calls = [];
  const request = async (path, { method = "GET", body } = {}) => {
    requests.push({ method, path, body });
    if (fail) throw fail;
    if (writeError && method !== "GET") throw writeError;
    if (path === "/api/v1/admin/model_providers") return { model_providers: providers };
    if (path === "/api/v1/admin/models") return { models };
    if (path === "/api/v1/admin/account/cost_unit") return { account: { cost_unit: "USD" } };
    const single = path.match(/^\/api\/v1\/admin\/model_providers\/([^/]+)$/);
    if (single) return { model_provider: providers.find((row) => row.id === single[1]), configuration: configurations[single[1]] };
    if (path.endsWith("/model_discovery")) return { models: [{ id: "a" }, { id: "b" }] };
    if (path.endsWith("/model_test")) return { model_test: { outcome: "succeeded", duration_ms: 320 }, model_provider: OPENROUTER };
    return { model_provider: OPENROUTER };
  };
  const refreshes = [];
  const shell = { nexus: { request }, toast: (text, tone) => calls.push(["toast", text, tone?.tone]), signIn: () => calls.push(["signIn"]),
    setup: { refresh: async () => refreshes.push(true), state: observable({ document: { nexus: { model_settings_url: "https://nexus.example/admin/model_providers" } } }) } };
  const view = nexusPage(shell);
  document.body.append(view.element);
  const lane = (id) => view.element.querySelector(`[data-provider="${id}"]`);
  const writes = () => requests.filter((request) => request.method !== "GET");
  const menuItems = () => document.body.querySelectorAll("[role=menuitem]").map((item) => [item.textContent, item.disabled, item.classList.contains("menu__item--danger")]);
  const pick = (text) => document.body.querySelectorAll("[role=menuitem]").find((item) => item.textContent === text).click();
  return { view, requests, calls, refreshes, lane, writes, menuItems, pick };
}

test("every lane is a card with its switch, its credential word and its menu; its models sit under it with their own title-row actions", async () => {
  const h = harness();
  await flush();
  expect(h.requests.map((request) => request.path)).toEqual(["/api/v1/admin/model_providers", "/api/v1/admin/models", "/api/v1/admin/account/cost_unit",
    "/api/v1/admin/model_providers/openrouter", "/api/v1/admin/model_providers/openai-codex", "/api/v1/admin/model_providers/local", "/api/v1/admin/model_providers/keyed"]);
  expect(h.view.element.querySelectorAll(".nexus-page__provider .card__title").map((node) => node.textContent)).toEqual(["OpenRouter", "OpenAI Codex", "local", "Keyed"]);
  const openrouter = h.lane("openrouter");
  expect(openrouter.querySelector('[name="enabled"]').checked).toBe(true);
  expect(openrouter.querySelector(".nexus-page__facts").textContent).toBe("openrouter");
  expect(h.lane("keyed").querySelector(".nexus-page__facts .tag").textContent).toBe("API key needed");
  expect(h.lane("openai-codex").querySelector(".nexus-page__facts .tag").textContent).toBe("Not connected");
  expect(openrouter.querySelectorAll(".nexus-page__models-head .group__actions button").map((node) => node.textContent)).toEqual(["Discover model IDs", "Add model"]);
  const rows = openrouter.querySelectorAll(".nexus-page__model");
  expect(rows.map((node) => node.dataset.model)).toEqual(["openrouter/z-ai/glm-5.3", "openrouter/hidden-one", "openrouter/broken"]);
  // A row: its name and only its own mark; what it is and can do on one line; its price.
  expect(rows[0].querySelector(".settings-row__label").textContent).toBe("GLM 5.3");
  expect(rows[0].querySelectorAll(".settings-row__description").map((node) => node.textContent)).toEqual(["Text generation · Tools · Streaming · openrouter/z-ai/glm-5.3", "USD 1.00 input / 2.00 output per 1M tokens"]);
  expect(rows.map((node) => [node.querySelector('[name="visible"]').checked, node.querySelector('[name="visible"]').disabled])).toEqual([[true, false], [false, false], [true, true]]);
  expect(rows.map((node) => node.querySelector(".tag")?.textContent ?? null)).toEqual([null, null, "Marked invalid"]);
  // A provider's state is said once, on its card: a disabled provider's models carry no mark.
  expect(h.lane("openai-codex").querySelectorAll(".nexus-page__model .tag")).toHaveLength(0);
  expect(openrouter.querySelector("[data-removed] .group__title").textContent).toBe("Removed models1");
  expect(openrouter.querySelector("[data-removed] button").textContent).toBe("Configure again");
  // Every API-key provider carries its key field: Save, and Remove while a key is saved; the hint says which.
  expect(openrouter.querySelector('[name="api_key"]').type).toBe("password");
  expect(openrouter.querySelectorAll(".nexus-page__key button").map((node) => node.textContent)).toEqual(["Save", "Remove"]);
  expect(openrouter.querySelector(".nexus-page__key .field__hint").textContent).toBe("A key is saved. Paste a new one to replace it.");
  expect(h.lane("keyed").querySelectorAll(".nexus-page__key button").map((node) => node.textContent)).toEqual(["Save"]);
  expect(h.lane("keyed").querySelector(".nexus-page__key .field__hint").textContent).toBe("Saved to Nexus and never shown again.");
  // An OAuth provider that is not connected offers its sign-in on the card; one without a credential offers nothing.
  expect(h.lane("openai-codex").querySelector(".card__body .btn--primary .btn__label").textContent).toBe("Authorize in Nexus");
  expect(h.lane("local").querySelector('[name="api_key"]')).toBeNull();
  // The subscription lane offers no discovery.
  expect(h.lane("openai-codex").querySelectorAll(".nexus-page__models-head .group__actions button").map((node) => node.textContent)).toEqual(["Add model"]);
  expect(h.lane("local").querySelector(".nexus-page__models-section").textContent).toContain("No models are configured yet");
  h.view.dispose();
});

test("the lane's menu keeps the rarer actions apart, the dangerous ones last", async () => {
  const h = harness();
  await flush();
  h.lane("openrouter").querySelector(".card__actions .btn--icon").click();
  expect(h.menuItems()).toEqual([["Edit connection", false, false], ["Restore the deployment's connection", false, true]]);
  h.pick("Edit connection");
  await flush();
  h.lane("openai-codex").querySelector(".card__actions .btn--icon").click();
  expect(h.menuItems()).toEqual([["Authorize in Nexus", false, false], ["Edit connection", false, false], ["Restore the deployment's connection", false, true]]);
  h.pick("Edit connection");
  h.lane("local").querySelector(".card__actions .btn--icon").click();
  expect(h.menuItems()).toEqual([["Edit connection", false, false], ["Delete connection", false, true]]);
  h.pick("Edit connection");
  h.view.dispose();
});

test("the switch, discovery, the key and its removal: one Nexus command each with the lane's version, then everything again", async () => {
  const h = harness();
  await flush();
  const codex = h.lane("openai-codex").querySelector('[name="enabled"]');
  codex.checked = true;
  codex.dispatchEvent(new Event("change"));
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openai-codex/lane", body: { command: { expected_lock_version: null, enabled: true } } });
  expect(h.calls.at(-1)).toEqual(["toast", "OpenAI Codex is enabled.", "success"]);
  expect(h.requests.filter((request) => request.path === "/api/v1/admin/models").length).toBe(2);

  h.lane("openrouter").querySelectorAll(".nexus-page__models-head .group__actions button").find((node) => node.textContent === "Discover model IDs").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "POST", path: "/api/v1/admin/model_providers/openrouter/model_discovery", body: { command: { expected_lock_version: 3 } } });
  expect(h.calls.at(-1)).toEqual(["toast", "OpenRouter lists 2 models upstream; configured ones it does not list are marked invalid.", "success"]);

  const key = h.lane("keyed").querySelector('[name="api_key"]');
  key.value = "  sk-secret  ";
  key.closest("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/keyed/api_key", body: { command: { api_key: "sk-secret" } } });
  expect(h.calls.at(-1)).toEqual(["toast", "The API key for Keyed was saved; the provider is enabled.", "success"]);

  // A saved key is replaced from the same field, and removed beside it after confirming.
  const rotate = h.lane("openrouter").querySelector('[name="api_key"]');
  rotate.value = "sk-new";
  rotate.closest("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openrouter/api_key", body: { command: { api_key: "sk-new" } } });

  h.lane("openrouter").querySelectorAll(".nexus-page__key button").find((node) => node.textContent === "Remove").click();
  const dialog = document.querySelector("dialog.modal");
  expect(dialog.querySelector(".modal__title").textContent).toBe("Remove the API key for OpenRouter?");
  dialog.querySelectorAll("button").find((node) => node.textContent === "Remove").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "DELETE", path: "/api/v1/admin/model_providers/openrouter/api_key", body: undefined });
  expect(h.calls.at(-1)).toEqual(["toast", "The API key for OpenRouter was removed.", "success"]);
  h.view.dispose();
});

test("a model's row: visibility by switch; Test, Edit, Clear invalid mark and Remove behind its menu; Configure again for a removed one", async () => {
  const h = harness();
  await flush();
  const hidden = h.lane("openrouter").querySelector('[data-model="openrouter/hidden-one"] [name="visible"]');
  hidden.checked = true;
  hidden.dispatchEvent(new Event("change"));
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openrouter/model_visibility",
    body: { command: { expected_lock_version: 3, model: "openrouter/hidden-one", visible: true } } });
  expect(h.calls.at(-1)).toEqual(["toast", "openrouter/hidden-one is visible to every agent again.", "success"]);

  h.lane("openrouter").querySelector('[data-model="openrouter/z-ai/glm-5.3"] .btn--icon').click();
  expect(h.menuItems()).toEqual([["Test", false, false], ["Edit model", false, false], ["Remove model", false, true]]);
  h.pick("Test");
  const dialog = document.querySelector("dialog.modal");
  expect(dialog.querySelector(".modal__title").textContent).toBe("Test openrouter/z-ai/glm-5.3?");
  dialog.querySelectorAll("button").find((node) => node.textContent === "Test").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "POST", path: "/api/v1/admin/model_providers/openrouter/model_test", body: { command: { expected_lock_version: 3, model: "openrouter/z-ai/glm-5.3" } } });
  expect(h.calls.at(-1)).toEqual(["toast", "openrouter/z-ai/glm-5.3: succeeded in 320 ms.", "success"]);

  h.lane("openrouter").querySelector('[data-model="openrouter/broken"] .btn--icon').click();
  expect(h.menuItems().map((item) => item[0])).toEqual(["Test", "Edit model", "Clear invalid mark", "Remove model"]);
  h.pick("Clear invalid mark");
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openrouter/model_availability", body: { command: { expected_lock_version: 3, model: "openrouter/broken", available: true } } });

  h.lane("openrouter").querySelector('[data-model="openrouter/broken"] .btn--icon').click();
  h.pick("Remove model");
  document.querySelector("dialog.modal").querySelectorAll("button").find((node) => node.textContent === "Remove model").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "DELETE", path: "/api/v1/admin/model_providers/openrouter/model_definition", body: { command: { expected_lock_version: 3, model: "openrouter/broken" } } });

  h.lane("openrouter").querySelector("[data-removed] button").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "POST", path: "/api/v1/admin/model_providers/openrouter/model_definition/reset", body: { command: { expected_lock_version: 3, model: "openrouter/old-one" } } });
  expect(h.calls.at(-1)).toEqual(["toast", "openrouter/old-one is back as the deployment declares it.", "success"]);
  h.view.dispose();
});

test("Add provider and Edit connection open the connection editor; saving PUTs the declaration over the one Nexus holds", async () => {
  const h = harness();
  await flush();
  // Add provider sits on the Providers group; the page's header keeps Refresh and the Nexus link.
  expect(h.view.element.querySelectorAll(".page__actions button").map((node) => node.getAttribute("aria-label"))).toEqual(["Refresh"]);
  h.view.element.querySelectorAll(".group__actions button").find((node) => node.textContent === "Add provider").click();
  const editor = h.view.element.querySelector('[data-editor="new-provider"]');
  expect(editor.querySelector(".card__title").textContent).toBe("Add provider");
  const control = (name) => editor.querySelector(`[name="${name}"]`);
  expect([...control("api_format").options].map((option) => option.value)).toEqual(PROTOCOLS);
  expect([...control("credentials").options].map((option) => option.value)).toEqual(["api_key", "none"]);
  control("provider_id").value = "Bad Id";
  control("base_url").value = "http://127.0.0.1:11434/v1";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(editor.querySelector(".field__error").textContent).toContain("lowercase letters");
  control("provider_id").value = "ollama";
  control("display_name").value = "Ollama";
  control("credentials").value = "none";
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/ollama/definition",
    body: { command: { expected_lock_version: null, definition: { display_name: "Ollama", api_format: "openai_compatible_chat", base_url: "http://127.0.0.1:11434/v1", credentials: "none" } } } });
  expect(h.calls.at(-1)).toEqual(["toast", "The connection for Ollama was saved.", "success"]);
  expect(h.view.element.querySelector('[data-editor="new-provider"]')).toBeNull();

  h.lane("openrouter").querySelector(".card__actions .btn--icon").click();
  h.pick("Edit connection");
  const connection = h.lane("openrouter").querySelector('[data-editor="connection:openrouter"]');
  expect(connection.querySelector('[name="provider_id"]').hasAttribute("readonly")).toBe(true);
  expect(connection.querySelector('[name="api_format"]').value).toBe("openrouter_chat");
  connection.querySelector('[name="concurrency_limit"]').value = "6";
  connection.querySelector("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openrouter/definition",
    body: { command: { expected_lock_version: 3, definition: { display_name: "OpenRouter", api_format: "openrouter_chat", base_url: "https://openrouter.ai/api/v1", credentials: "api_key", wire_options: { keep: true }, concurrency_limit: 6 } } } });
  expect(h.lane("openrouter").querySelector("[data-editor]")).toBeNull();

  // The Codex lane's connection keeps its subscription sign-in.
  h.lane("openai-codex").querySelector(".card__actions .btn--icon").click();
  h.pick("Edit connection");
  const codex = h.lane("openai-codex").querySelector('[data-editor="connection:openai-codex"]');
  expect([...codex.querySelector('[name="credentials"]').options].map((option) => option.value)).toEqual(["codex"]);
  expect([...codex.querySelector('[name="api_format"]').options].map((option) => option.value)).toContain("codex_responses");
  h.view.dispose();
});

test("Add model and Edit model open the model editor; a refused save stays in the form; deleting a custom connection asks first", async () => {
  const h = harness();
  await flush();
  h.lane("openrouter").querySelectorAll(".nexus-page__models-head .group__actions button").find((node) => node.textContent === "Add model").click();
  const adding = h.lane("openrouter").querySelector('[data-editor="new-model:openrouter"]');
  expect(adding.querySelector(".card__title").textContent).toBe("Add a model to OpenRouter");
  expect([...adding.querySelector('[name="pricing_mode"]').options].map((option) => option.value)).toEqual(["none", "custom"]);
  expect(adding.querySelector('[name="pricing_unit"]').value).toBe("USD");
  adding.querySelector('[name="model_id"]').value = "meta/llama-4";
  adding.querySelector('[name="input_tokens"]').value = "128000";
  adding.querySelector('[name="tool_calls"]').value = "true";
  adding.querySelector("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/openrouter/model_definition",
    body: { command: { expected_lock_version: 3, model: "openrouter/meta/llama-4", definition: { model_id: "meta/llama-4", capabilities: { limits: { input_tokens: 128000 }, tool_calls: true } } } } });
  expect(h.calls.at(-1)).toEqual(["toast", "openrouter/meta/llama-4 was saved.", "success"]);

  h.lane("openrouter").querySelector('[data-model="openrouter/z-ai/glm-5.3"] .btn--icon').click();
  h.pick("Edit model");
  const editing = h.lane("openrouter").querySelector('[data-editor="model:openrouter/z-ai/glm-5.3"]');
  expect(editing.querySelector('[name="model_id"]').value).toBe("z-ai/glm-5.3");
  expect(editing.querySelector('[name="display_name"]').value).toBe("GLM 5.3");
  expect(editing.querySelector('[name="input_tokens"]').value).toBe("200000");
  editing.querySelectorAll("button").find((node) => node.textContent === "Cancel").click();
  expect(h.lane("openrouter").querySelector("[data-editor]")).toBeNull();

  const refused = harness({ writeError: Object.assign(new Error("base_url must be an absolute http(s) origin"), { status: 422, code: "validation_failed", nexus: true }) });
  await flush();
  refused.lane("local").querySelector(".card__actions .btn--icon").click();
  refused.pick("Edit connection");
  const connection = refused.lane("local").querySelector("[data-editor]");
  connection.querySelector("form").requestSubmit();
  await flush();
  expect(refused.lane("local").querySelector("[data-editor] .alert__text").textContent).toBe("base_url must be an absolute http(s) origin");
  expect(refused.view.element.querySelector(".page__body > .alert--error").hidden).toBe(true);
  refused.view.dispose();

  h.lane("local").querySelector(".card__actions .btn--icon").click();
  h.pick("Delete connection");
  const dialog = document.querySelector("dialog.modal");
  expect(dialog.querySelector(".modal__title").textContent).toBe("Remove the connection for local?");
  dialog.querySelectorAll("button").find((node) => node.textContent === "Delete connection").click();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "DELETE", path: "/api/v1/admin/model_providers/local/definition", body: { command: { expected_lock_version: 0 } } });
  h.view.dispose();
});

test("a local model inherits a shared definition while saving only its 32K deployment limit", async () => {
  const definitions = { "compact-base": { display_name: "Compact Base", capabilities: {
    limits: { combined_input_output_tokens: 1000000, output_tokens: 131072 }, reasoning: { disable_supported: true, default_enabled: true } } } };
  const h = harness({ configurations: { ...CONFIGURATIONS, local: { ...CONFIGURATIONS.local, model_definitions: definitions } } });
  await flush();
  h.lane("local").querySelectorAll(".nexus-page__models-head .group__actions button").find((node) => node.textContent === "Add model").click();
  const editor = h.lane("local").querySelector("[data-editor]");
  const inherit = editor.querySelector('[name="inherit"]');
  expect([...inherit.options].map((option) => [option.value, option.textContent])).toEqual([["", "Custom definition"], ["compact-base", "Compact Base"]]);
  inherit.value = "compact-base";
  inherit.dispatchEvent(new Event("change"));
  editor.querySelector('[name="model_id"]').value = "local-weights";
  editor.querySelector('[name="combined_input_output_tokens"]').value = "32768";
  expect(editor.querySelector('[name="output_tokens"]').value).toBe("");
  editor.querySelector("form").requestSubmit();
  await flush();
  expect(h.writes().at(-1)).toEqual({ method: "PUT", path: "/api/v1/admin/model_providers/local/model_definition",
    body: { command: { expected_lock_version: 0, model: "local/local-weights", definition: {
      model_id: "local-weights", inherit: "compact-base", capabilities: { limits: { combined_input_output_tokens: 32768 } } } } } });
  h.view.dispose();
});

test("model edits retain an inheritance reference without copying its capabilities and can remove that reference", () => {
  const current = { inherit: "compact-base", model_id: "local-weights", wire_options: { prompt_format: "qwen3_5" } };
  expect(modelDefinition(current, { inherit: "compact-base", model_id: "local-weights", display_name: "My model", pricing_mode: "none" }))
    .toEqual({ ...current, display_name: "My model" });
  expect(modelDefinition(current, { inherit: "", model_id: "local-weights", pricing_mode: "none" }))
    .toEqual({ model_id: "local-weights", wire_options: { prompt_format: "qwen3_5" } });
});

test("an unlock-only page is asked to sign in; a member is told whose this is; a stale write is said and reread", async () => {
  const gated = harness({ fail: Object.assign(new Error("Sign in with Nexus"), { status: 403, code: "human_login_required" }) });
  await flush();
  expect(gated.view.element.querySelector(".empty-state__title").textContent).toBe("Sign in with Nexus first");
  expect(gated.view.element.querySelector(".nexus-page__lanes").hidden).toBe(true);
  gated.view.element.querySelector(".empty-state button").click();
  expect(gated.calls).toEqual([["signIn"]]);
  gated.view.dispose();

  const member = harness({ fail: Object.assign(new Error("administrator required"), { status: 403, code: "administrator_required" }) });
  await flush();
  expect(member.view.element.querySelector(".empty-state__title").textContent).toBe("Administrator access required");
  member.view.dispose();

  const stale = harness({ writeError: Object.assign(new Error("changed"), { status: 409, code: "stale_object", nexus: true }) });
  await flush();
  const reads = () => stale.requests.filter((request) => request.method === "GET").length;
  const before = reads();
  const toggle = stale.lane("local").querySelector('[name="enabled"]');
  toggle.checked = true;
  toggle.dispatchEvent(new Event("change"));
  await flush();
  expect(stale.calls.at(-1)).toEqual(["toast", "Someone changed this provider meanwhile; the page has reread it.", "error"]);
  expect(reads()).toBe(before * 2);
  stale.view.dispose();
});


test("enabling a provider refreshes the shared model choices without reopening a page", async () => {
  const h = harness();
  await flush();
  expect(h.refreshes).toHaveLength(0);
  h.lane("local").querySelector('[name="enabled"]').click();
  await flush();
  expect(h.writes()[0].body.command.enabled).toBe(true);
  expect(h.refreshes).toHaveLength(1);
  h.view.dispose();
});
