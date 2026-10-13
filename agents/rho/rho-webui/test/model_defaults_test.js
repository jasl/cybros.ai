import { test, expect, beforeEach, afterEach } from "bun:test";
import { installDocument, flush } from "./support/dom.js";
import { modelEditor } from "../webui/features/nexus/editors.js";

let restore;
beforeEach(() => { restore = installDocument(); });
afterEach(() => restore());

const BASES = {
  compact: { capabilities: { limits: { combined_input_output_tokens: 1000000, output_tokens: 131072 },
    tool_calls: false, input_modalities: ["image"], reasoning: { disable_supported: true, default_enabled: true, efforts: ["low", "high"], default_effort: "high" } } },
  alternate: { capabilities: { limits: { input_tokens: 64000, output_tokens: 4096 }, tool_calls: true,
    streaming: false, input_modalities: [], reasoning: null } },
  unspecified: { capabilities: {} },
};

function editor(definition = { model_id: "local-weights" }) {
  const writes = [];
  const view = modelEditor({ provider: { id: "local" }, format: "openai_compatible_chat", model: "local/local-weights",
    definition, modelDefinitions: BASES, save: async (ref, value) => { writes.push([ref, value]); return "Keep editing"; }, onClose() {} });
  document.body.append(view.element);
  const control = (name) => view.element.querySelector(`[name="${name}"]`);
  const set = (name, value, event = "change") => { control(name).value = value; control(name).dispatchEvent(new Event(event)); };
  const hint = (name) => control(name).closest(".field").querySelector(".field__hint").textContent;
  const save = async () => { view.form.requestSubmit(); await flush(); return writes.at(-1)[1]; };
  const useModelLimits = () => view.element.querySelectorAll("button").find((node) => node.textContent === "Use model limits").click();
  return { view, control, set, hint, save, useModelLimits };
}

test("choosing a definition shows its defaults without copying them into the saved declaration", async () => {
  const h = editor();
  h.set("inherit", "compact");
  expect(h.control("combined_input_output_tokens").value).toBe("");
  expect(h.control("combined_input_output_tokens").placeholder).toContain("1000000");
  expect(h.hint("combined_input_output_tokens")).toContain("1,000,000");
  expect(h.hint("output_tokens")).toContain("131,072");
  expect(h.control("tool_calls").selectedOptions[0].textContent).toContain("Disabled");
  expect(h.control("streaming").selectedOptions[0].textContent.toLowerCase()).toContain("protocol");
  expect(h.view.element.textContent).toContain("high");
  expect(h.view.element.textContent).toContain("Images");
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact" });
});

test("limits replace one complete window and clearing the last override restores the inherited window", async () => {
  const h = editor({ model_id: "local-weights", inherit: "compact" });
  h.set("combined_input_output_tokens", "32768", "input");
  expect(h.control("output_tokens").placeholder).toBe("");
  expect(h.hint("output_tokens").toLowerCase()).toContain("not inherited");
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact", capabilities: { limits: { combined_input_output_tokens: 32768 } } });
  h.set("output_tokens", "2048", "input");
  h.set("combined_input_output_tokens", "", "input");
  expect(h.control("combined_input_output_tokens").placeholder).toBe("");
  h.set("output_tokens", "", "input");
  expect(h.control("output_tokens").placeholder).toBe("131072");
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact" });
});

test("an explicit empty or non-text limits block remains a replacement until the user chooses model limits", async () => {
  for (const limits of [{}, { input_bytes: 2000 }]) {
    const original = { model_id: "local-weights", inherit: "compact", capabilities: { limits } };
    const h = editor(original);
    expect(h.control("output_tokens").placeholder).toBe("");
    expect(h.hint("output_tokens").toLowerCase()).toContain("not inherited");
    expect(await h.save()).toEqual(original);
    h.useModelLimits();
    expect(h.control("output_tokens").placeholder).toBe("131072");
    expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact" });
    h.set("combined_input_output_tokens", "32768", "input");
    expect((await h.save()).capabilities.limits).toEqual({ combined_input_output_tokens: 32768 });
    h.view.dispose();
  }
});

test("switching definitions refreshes default hints while keeping explicit overrides and unexposed values", async () => {
  const original = { model_id: "local-weights", inherit: "compact", display_name: "My local model", token_counter: null,
    capabilities: { limits: { combined_input_output_tokens: 32768 }, tool_calls: false, input_modalities: [], reasoning: null },
    wire_options: { sample: true }, pricing: { account_unit: "USD", schedule: { kind: "catalog_only", rates: { input_per_mtok: "1" } } } };
  const h = editor(original);
  h.set("inherit", "alternate");
  expect(h.hint("output_tokens")).toContain("4,096");
  expect(h.control("tool_calls").value).toBe("false");
  expect(h.control("tool_calls").options[0].textContent).toContain("Supported");
  expect(h.control("combined_input_output_tokens").value).toBe("32768");
  expect(h.control("input_modalities_mode").value).toBe("custom");
  expect(await h.save()).toEqual({ ...original, inherit: "alternate" });
  h.set("inherit", "unspecified");
  expect(h.control("tool_calls").options[0].textContent.toLowerCase()).toContain("protocol");
  h.set("inherit", "");
  expect(h.control("output_tokens").placeholder).toBe("");
  expect(h.hint("output_tokens")).not.toContain("4,096");
  const { inherit, ...withoutInheritance } = original;
  expect(await h.save()).toEqual(withoutInheritance);
});

test("media defaults can be narrowed to text only and then restored to inheritance", async () => {
  const h = editor({ model_id: "local-weights", inherit: "compact" });
  expect(h.control("input_modalities_mode").value).toBe("inherit");
  h.set("input_modalities_mode", "custom");
  expect(h.control("input_modalities_image").checked).toBe(true);
  h.control("input_modalities_image").checked = false;
  h.control("input_modalities_image").dispatchEvent(new Event("change"));
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact", capabilities: { input_modalities: [] } });
  h.set("inherit", "alternate");
  expect(h.control("input_modalities_image").checked).toBe(false);
  h.set("input_modalities_mode", "inherit");
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "alternate" });
});

test("explicit values equal to a model default stay explicit", async () => {
  const h = editor({ model_id: "local-weights", inherit: "compact" });
  h.set("combined_input_output_tokens", "1000000", "input");
  h.set("tool_calls", "false");
  h.set("input_modalities_mode", "custom");
  expect(await h.save()).toEqual({ model_id: "local-weights", inherit: "compact", capabilities: {
    limits: { combined_input_output_tokens: 1000000 }, tool_calls: false, input_modalities: ["image"] } });
});
