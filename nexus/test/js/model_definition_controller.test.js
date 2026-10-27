import { expect, test } from "bun:test"
import { file, YAML } from "bun"
import ModelDefinitionController from "../../app/javascript/controllers/model_definition_controller"

const { en } = YAML.parse(await file(new URL("../../config/locales/model_provider_views.en.yml", import.meta.url)).text())
const copy = en.admin.model_providers.model_definitions.form
const limitKeys = ["input_tokens", "output_tokens", "combined_input_output_tokens", "effective_input_tokens"]
const mediaKinds = ["image", "audio", "video", "file"]
const translated = (key, value) => copy[key].replace("%{value}", value)

// The server supplies localized display data; these fixtures exercise how the
// controller applies that data without turning it into authored form values.
function defaults({ limits = {}, booleans = {}, media = null, facts = [], promptCache = { options: [[copy.prompt_cache_default, ""]], default: "", supported: false } } = {}) {
  const mediaValue = media?.length ? media.map(kind => copy.media_types[kind] || kind).join(", ") : copy.media_text_only
  return {
    facts,
    promptCache,
    limits: Object.fromEntries(limitKeys.map(key => [key, Object.hasOwn(limits, key) ? {
      placeholder: String(limits[key]), inherited: translated("inherited_default", limits[key].toLocaleString("en")),
      overridden: translated("model_default_not_inherited", limits[key].toLocaleString("en")),
    } : { placeholder: "", inherited: copy.protocol_default_unspecified, overridden: copy.protocol_default_unspecified }])),
    booleans: Object.fromEntries(["tool_calls", "streaming"].map(key => [key, Object.hasOwn(booleans, key) ? {
      label: translated("use_model_default", booleans[key] ? copy.supported : copy.disabled),
      hint: translated("model_default", booleans[key] ? copy.supported : copy.disabled),
    } : { label: copy.use_protocol_default_unspecified, hint: copy.protocol_default_unspecified }])),
    media: { values: media || [], inherited: media ? translated("inherited_default", mediaValue) : copy.protocol_default_unspecified,
      custom: media ? translated("model_default", mediaValue) : copy.protocol_default_unspecified },
  }
}

const definitions = {
  compact: defaults({ limits: { combined_input_output_tokens: 65536, output_tokens: 4096 },
    booleans: { tool_calls: false }, media: ["image"], facts: [
      { label: "Limits / Combined context window", value: "65,536" },
      { label: "Reasoning / Supported efforts", value: "low, high" },
    ] }),
  wide: defaults({ limits: { combined_input_output_tokens: 128000, output_tokens: 8192 },
    booleans: { tool_calls: true, streaming: false }, media: [], facts: [{ label: "Reasoning", value: "Explicitly unset" }] }),
  unspecified: defaults(),
  additional: defaults({ media: ["image", "other-media"] }),
}

function element() {
  return { children: [], hidden: false, disabled: false, textContent: "", value: "",
    append(...children) { this.children.push(...children) },
    replaceChildren(...children) { this.children = children },
  }
}

function withController(run, { inherit = "compact", limits = {}, emptyLimits = false, otherLimits = false,
  mediaMode = "inherit", media = [], resetLimits = false, limitsEdited = false } = {}) {
  const original = globalThis.document
  globalThis.document = { createElement: element }
  const controller = Object.assign(Object.create(ModelDefinitionController.prototype), {
    definitionsValue: definitions, fallbackValue: defaults(), emptyLimitsValue: emptyLimits, otherLimitsValue: otherLimits,
    currentMediaValue: media, messagesValue: { textOnly: copy.media_text_only_hint, additionalMedia: copy.media_additional_saved },
    inheritTarget: { value: inherit }, defaultsTarget: element(), factsTarget: element(), emptyFactsTarget: element(),
    resetLimitsTarget: { value: String(resetLimits) }, limitsEditedTarget: { value: String(limitsEdited) }, restoreLimitsTarget: element(),
    limitTargets: limitKeys.map(key => ({ value: String(limits[key] ?? ""), placeholder: "", dataset: { limit: key } })),
    limitHintTargets: limitKeys.map(key => ({ textContent: "", dataset: { limit: key } })),
    booleanTargets: ["tool_calls", "streaming"].map(key => ({ value: "", options: [{ textContent: "" }], dataset: { capability: key } })),
    booleanHintTargets: ["tool_calls", "streaming"].map(key => ({ textContent: "", dataset: { capability: key } })),
    mediaModeTarget: { value: mediaMode }, mediaTargets: mediaKinds.map(value => ({ value, checked: media.includes(value), disabled: false })),
    mediaHintTarget: element(), extraMediaTarget: element(), promptCacheTarget: element(), promptCacheSectionTarget: element(),
  })
  const limit = key => controller.limitTargets.find(control => control.dataset.limit === key)
  const hint = key => controller.limitHintTargets.find(control => control.dataset.limit === key).textContent
  const choose = value => { controller.inheritTarget.value = value; controller.definitionChanged() }
  const mediaChoice = value => { controller.mediaModeTarget.value = value; controller.mediaModeChanged() }
  try {
    controller.connect()
    run({ controller, limit, hint, choose, mediaChoice })
  } finally {
    if (original === undefined) delete globalThis.document
    else globalThis.document = original
  }
}

test("definition defaults are visible without filling authored input values", () => {
  withController(({ controller, limit, hint, choose }) => {
    expect(controller.defaultsTarget.hidden).toBe(false)
    expect(controller.factsTarget.children.map(row => row.children[1].textContent)).toEqual(["65,536", "low, high"])
    expect(limit("combined_input_output_tokens").value).toBe("")
    expect(limit("combined_input_output_tokens").placeholder).toBe("65536")
    expect(hint("combined_input_output_tokens")).toBe("Inherited: 65,536")
    expect(controller.booleanTargets[0].options[0].textContent).toBe("Use model default (Disabled)")
    expect(controller.booleanTargets[1].options[0].textContent).toBe(copy.use_protocol_default_unspecified)
    expect(controller.booleanTargets.map(control => control.value)).toEqual(["", ""])
    choose("unspecified")
    expect(controller.defaultsTarget.hidden).toBe(false)
    expect(controller.emptyFactsTarget.hidden).toBe(false)
    choose("")
    expect(controller.defaultsTarget.hidden).toBe(true)
    expect(limit("combined_input_output_tokens").placeholder).toBe("")
  })
})

test("one context override removes inherited placeholders for the entire window until all edits are cleared", () => {
  withController(({ controller, limit, hint }) => {
    limit("combined_input_output_tokens").value = "32768"
    controller.limitsChanged()
    expect(controller.limitsEditedTarget.value).toBe("true")
    expect(limit("output_tokens").placeholder).toBe("")
    expect(hint("output_tokens")).toContain("not inherited")
    expect(controller.restoreLimitsTarget.hidden).toBe(false)
    limit("output_tokens").value = "2048"
    limit("combined_input_output_tokens").value = ""
    controller.limitsChanged()
    expect(limit("combined_input_output_tokens").placeholder).toBe("")
    limit("output_tokens").value = ""
    controller.limitsChanged()
    expect(limit("output_tokens").placeholder).toBe("4096")
    expect(controller.restoreLimitsTarget.hidden).toBe(true)
  })
})

test("empty and unexposed limits stay overridden until the complete window is explicitly reset", () => {
  for (const state of [{ emptyLimits: true }, { otherLimits: true }]) {
    withController(({ controller, limit, hint }) => {
      expect(limit("output_tokens").placeholder).toBe("")
      expect(hint("output_tokens")).toContain("not inherited")
      expect(controller.resetLimitsTarget.value).toBe("false")
      expect(controller.limitsEditedTarget.value).toBe("false")
      controller.useModelLimits()
      expect(controller.resetLimitsTarget.value).toBe("true")
      expect(controller.limitsEditedTarget.value).toBe("true")
      expect(controller.limitTargets.every(control => control.value === "")).toBe(true)
      expect(limit("output_tokens").placeholder).toBe("4096")
      expect(controller.restoreLimitsTarget.hidden).toBe(true)
    }, state)
  }
})

test("validation redisplay retains a reset even when the original window contains unexposed values", () => {
  withController(({ controller, limit }) => {
    expect(limit("output_tokens").placeholder).toBe("4096")
    expect(controller.resetLimitsTarget.value).toBe("true")
    expect(controller.restoreLimitsTarget.hidden).toBe(true)
    limit("combined_input_output_tokens").value = "32768"
    controller.limitsChanged()
    expect(controller.resetLimitsTarget.value).toBe("true")
    expect(limit("output_tokens").placeholder).toBe("")
  }, { otherLimits: true, resetLimits: true, limitsEdited: true })
})

test("switching definitions updates defaults and preserves explicit limits, booleans and text-only media", () => {
  withController(({ controller, limit, hint, choose }) => {
    controller.booleanTargets[0].value = "false"
    choose("wide")
    expect(limit("combined_input_output_tokens").value).toBe("32768")
    expect(hint("output_tokens")).toContain("8,192")
    expect(controller.booleanTargets[0].value).toBe("false")
    expect(controller.booleanTargets[0].options[0].textContent).toBe("Use model default (Supported)")
    expect(controller.mediaModeTarget.value).toBe("custom")
    expect(controller.mediaTargets.every(control => !control.checked)).toBe(true)
    expect(controller.mediaHintTarget.textContent).toContain(copy.media_text_only_hint)
    choose("compact")
    expect(controller.mediaTargets.every(control => !control.checked)).toBe(true)
  }, { limits: { combined_input_output_tokens: 32768 }, mediaMode: "custom" })
})

test("media can use inherited support, become text-only, and return to inheritance", () => {
  withController(({ controller, mediaChoice }) => {
    expect(controller.mediaTargets[0].checked).toBe(true)
    expect(controller.mediaTargets.every(control => control.disabled)).toBe(true)
    mediaChoice("custom")
    expect(controller.mediaTargets[0].checked).toBe(true)
    expect(controller.mediaTargets.every(control => !control.disabled)).toBe(true)
    controller.mediaTargets[0].checked = false
    controller.paintMedia()
    expect(controller.mediaHintTarget.textContent).toContain(copy.media_text_only_hint)
    mediaChoice("inherit")
    expect(controller.mediaTargets[0].checked).toBe(true)
    expect(controller.mediaTargets.every(control => control.disabled)).toBe(true)
    expect(controller.mediaHintTarget.textContent).toBe("Inherited: Images")
  })
})

test("unexposed media is carried by hidden inputs for custom values and disabled during inheritance", () => {
  withController(({ controller, choose, mediaChoice }) => {
    expect(controller.extraMediaTarget.children.map(input => input.value)).toEqual(["existing-media"])
    expect(controller.extraMediaTarget.children[0].name).toBe("model_definition[input_modalities][]")
    expect(controller.extraMediaTarget.children[0].disabled).toBe(false)
    choose("additional")
    expect(controller.extraMediaTarget.children.map(input => input.value)).toEqual(["existing-media"])
    mediaChoice("inherit")
    expect(controller.extraMediaTarget.children[0].disabled).toBe(true)
    mediaChoice("custom")
    expect(controller.extraMediaTarget.children.map(input => input.value)).toEqual(["other-media"])
    expect(controller.extraMediaTarget.children[0].disabled).toBe(false)
    expect(controller.mediaTargets[0].checked).toBe(true)
    expect(controller.mediaHintTarget.textContent).toContain("other-media")
  }, { mediaMode: "custom", media: ["existing-media"] })
})
