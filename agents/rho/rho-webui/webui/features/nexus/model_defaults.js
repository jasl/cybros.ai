import { el } from "../../kernel/dom.js";
import { locale, t } from "../../kernel/i18n.js";
import { checkbox, field, formGroup, list, select } from "../../primitives/index.js";

const MEDIA = ["image", "audio", "video", "file"];
const numbers = new Intl.NumberFormat(locale);

const factLabel = (path) => path.map((key) => t(`nexus.fact_${key}`, {}, key)).join(" / ");

function factValue(value, path = []) {
  if (value === null) return t("nexus.default_null");
  if (value === true) return path.at(-1) === "disable_supported" ? t("nexus.default_yes") : t("nexus.default_enabled");
  if (value === false) return path.at(-1) === "disable_supported" ? t("nexus.default_no") : t("nexus.capability_disabled");
  if (typeof value === "number") return numbers.format(value);
  if (Array.isArray(value)) {
    if (!value.length) return path.at(-1) === "input_modalities" ? t("nexus.media_text_only") : t("nexus.default_empty_list");
    return value.map((item) => path.at(-1) === "input_modalities" ? t(`nexus.media_${item}`, {}, String(item)) : factValue(item)).join(", ");
  }
  if (typeof value === "object") return Object.keys(value).length ? JSON.stringify(value) : t("nexus.default_empty_object");
  return String(value);
}

function factRows(value, path = []) {
  if (value !== null && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length) {
    return Object.entries(value).flatMap(([key, nested]) => factRows(nested, [...path, key]));
  }
  return [{ key: path.join("."), label: factLabel(path), detail: factValue(value, path) }];
}

// Defaults are a read-only projection of the selected definition. Keeping
// them out of input values preserves the distinction between inheritance
// and an explicit override that happens to equal today's default.
export function modelDefaults({ inherit, modelDefinitions, capabilities, limitInputs, limitFields, booleanInputs, booleanFields }) {
  let limitsOverridden = false;
  const summary = formGroup({ title: t("nexus.definition_defaults"), description: t("nexus.definition_defaults_hint"),
    attrs: { "data-model-defaults": "" } });
  const facts = list({ empty: t("nexus.definition_defaults_empty") });
  summary.append(facts.element);
  summary.element.hidden = true;

  const initialMedia = Object.hasOwn(capabilities, "input_modalities");
  let customMedia = initialMedia ? [...capabilities.input_modalities] : [];
  let previousMode = initialMedia ? "custom" : "inherit";
  const mode = select({ name: "input_modalities_mode", value: previousMode, options: [
    { value: "inherit", label: t("nexus.media_inherit") }, { value: "custom", label: t("nexus.media_custom") },
  ] });
  const modeField = field({ label: t("nexus.media_mode"), control: mode });
  const mediaControls = Object.fromEntries(MEDIA.map((kind) => [kind,
    checkbox({ name: `input_modalities_${kind}`, label: t(`nexus.media_${kind}`), checked: customMedia.includes(kind), onChange: () => paintMedia() }),
  ]));
  const media = formGroup({ title: t("nexus.input_media"), description: t("nexus.media_override_hint") });
  media.append(modeField.element, el("div", { class: "stack stack--tight" }, ...Object.values(mediaControls).map((control) => control.element)));

  const selected = () => modelDefinitions[inherit.value];
  const inheritedMedia = () => selected()?.capabilities?.input_modalities ?? [];
  const selectedMedia = () => {
    const checked = MEDIA.filter((kind) => mediaControls[kind].input.checked);
    // An existing declaration may name a type this editor does not offer.
    // Editing its known checkboxes does not discard that saved fact.
    return [...customMedia.filter((kind) => !MEDIA.includes(kind) || checked.includes(kind)),
      ...checked.filter((kind) => !customMedia.includes(kind))];
  };

  function paintMedia() {
    const inherited = mode.value === "inherit";
    const base = selected()?.capabilities ?? {};
    for (const kind of MEDIA) {
      mediaControls[kind].input.disabled = inherited;
      if (inherited) mediaControls[kind].input.checked = inheritedMedia().includes(kind);
    }
    let hint = t("nexus.protocol_default_unspecified");
    if (Object.hasOwn(base, "input_modalities")) {
      const value = factValue(base.input_modalities, ["input_modalities"]);
      hint = inherited ? t("nexus.inherited_default", { value }) : t("nexus.model_default", { value });
    }
    if (!inherited) {
      const chosen = selectedMedia();
      if (!chosen.length) hint += ` ${t("nexus.media_text_only_hint")}`;
      const additional = chosen.filter((kind) => !MEDIA.includes(kind));
      if (additional.length) hint += ` ${t("nexus.media_additional_saved", { values: additional.join(", ") })}`;
    }
    modeField.setHint(hint);
  }

  function paint({ limitsOverridden: overridden = limitsOverridden } = {}) {
    limitsOverridden = overridden;
    const definition = selected();
    const base = definition?.capabilities ?? {};
    summary.element.hidden = !definition;
    facts.update(Object.keys(base).length ? factRows(base) : []);
    for (const [key, control] of Object.entries(limitInputs)) {
      const defined = Object.hasOwn(base.limits ?? {}, key);
      control.placeholder = defined && !limitsOverridden ? String(base.limits[key]) : "";
      let hint = t("nexus.protocol_default_unspecified");
      if (defined) {
        const value = factValue(base.limits[key]);
        hint = limitsOverridden ? t("nexus.model_default_not_inherited", { value }) : t("nexus.inherited_default", { value });
      }
      limitFields[key].setHint(hint);
    }
    for (const [key, control] of Object.entries(booleanInputs)) {
      const defined = Object.hasOwn(base, key);
      const value = base[key] === true ? t("nexus.capability_supported") : factValue(base[key]);
      control.options[0].textContent = defined
        ? t("nexus.use_model_default", { value })
        : t("nexus.use_protocol_default");
      booleanFields[key].setHint(defined
        ? t("nexus.model_default", { value })
        : t("nexus.protocol_default_unspecified"));
    }
    paintMedia();
  }

  mode.addEventListener("change", () => {
    if (mode.value === "custom" && previousMode !== "custom") {
      customMedia = [...inheritedMedia()];
      for (const kind of MEDIA) mediaControls[kind].input.checked = customMedia.includes(kind);
    }
    previousMode = mode.value;
    paintMedia();
  });
  inherit.addEventListener("change", () => paint());

  return { element: summary.element, mediaElement: media.element, paint,
    values: () => ({ input_modalities_mode: mode.value, input_modalities: mode.value === "custom" ? selectedMedia() : [...inheritedMedia()] }) };
}
