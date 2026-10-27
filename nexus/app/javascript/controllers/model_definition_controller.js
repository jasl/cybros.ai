import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["inherit", "defaults", "facts", "emptyFacts", "limit", "limitHint", "boolean", "booleanHint",
    "resetLimits", "limitsEdited", "restoreLimits", "mediaMode", "media", "mediaHint", "extraMedia", "promptCache", "promptCacheSection"]
  static values = { definitions: Object, fallback: Object, emptyLimits: Boolean, otherLimits: Boolean,
    currentMedia: Array, messages: Object }

  connect() {
    this.customMedia = [...this.currentMediaValue]
    this.previousMediaMode = this.mediaModeTarget.value
    this.definitionChanged()
  }

  definitionChanged(event) {
    const defaults = this.selectedDefaults()
    this.defaultsTarget.hidden = !Object.hasOwn(this.definitionsValue, this.inheritTarget.value)
    this.factsTarget.replaceChildren(...defaults.facts.map(fact => {
      const row = document.createElement("div")
      row.className = "min-w-0"
      const label = document.createElement("dt")
      label.className = "text-xs text-base-content/60 wrap-anywhere"
      label.textContent = fact.label
      const value = document.createElement("dd")
      value.className = "mt-1 text-sm wrap-anywhere"
      value.textContent = fact.value
      row.append(label, value)
      return row
    }))
    this.emptyFactsTarget.hidden = defaults.facts.length > 0
    for (const control of this.booleanTargets) control.options[0].textContent = defaults.booleans[control.dataset.capability].label
    for (const hint of this.booleanHintTargets) hint.textContent = defaults.booleans[hint.dataset.capability].hint
    this.paintLimits()
    this.paintMedia()
    this.paintPromptCache(Boolean(event))
  }

  paintPromptCache(reset) {
    const defaults = this.selectedDefaults().promptCache
    const selected = reset ? defaults.default : this.promptCacheTarget.value
    this.promptCacheSectionTarget.hidden = !defaults.supported
    this.promptCacheTarget.disabled = !defaults.supported
    this.promptCacheTarget.replaceChildren(...defaults.options.map(([label, value]) => {
      const option = document.createElement("option")
      option.textContent = label
      option.value = value
      option.selected = value === selected
      return option
    }))
  }

  limitsChanged() {
    this.limitsEditedTarget.value = "true"
    this.paintLimits()
  }

  useModelLimits() {
    for (const control of this.limitTargets) control.value = ""
    this.resetLimitsTarget.value = "true"
    this.limitsEditedTarget.value = "true"
    this.paintLimits()
  }

  mediaModeChanged() {
    if (this.mediaModeTarget.value === "custom" && this.previousMediaMode !== "custom") {
      this.customMedia = [...this.selectedDefaults().media.values]
      for (const control of this.mediaTargets) control.checked = this.customMedia.includes(control.value)
    }
    this.previousMediaMode = this.mediaModeTarget.value
    this.paintMedia()
  }

  paintLimits() {
    const reset = this.resetLimitsTarget.value === "true"
    const edited = this.limitsEditedTarget.value === "true"
    const overridden = this.limitTargets.some(control => control.value.trim() !== "") ||
      (!reset && (this.otherLimitsValue || (this.emptyLimitsValue && !edited)))
    const defaults = this.selectedDefaults().limits
    this.restoreLimitsTarget.hidden = !overridden
    for (const control of this.limitTargets) control.placeholder = overridden ? "" : defaults[control.dataset.limit].placeholder
    for (const hint of this.limitHintTargets) hint.textContent = defaults[hint.dataset.limit][overridden ? "overridden" : "inherited"]
  }

  paintMedia() {
    const inherited = this.mediaModeTarget.value === "inherit"
    const defaults = this.selectedDefaults().media
    for (const control of this.mediaTargets) {
      control.disabled = inherited
      if (inherited) control.checked = defaults.values.includes(control.value)
    }
    const known = this.mediaTargets.map(control => control.value)
    const additional = this.customMedia.filter(value => !known.includes(value))
    this.extraMediaTarget.replaceChildren(...additional.map(value => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "model_definition[input_modalities][]"
      input.value = value
      input.disabled = inherited
      return input
    }))
    let hint = defaults[inherited ? "inherited" : "custom"]
    if (!inherited) {
      if (!this.mediaTargets.some(control => control.checked) && !additional.length) hint += ` ${this.messagesValue.textOnly}`
      if (additional.length) hint += ` ${this.messagesValue.additionalMedia.replace("%{values}", additional.join(", "))}`
    }
    this.mediaHintTarget.textContent = hint
  }

  selectedDefaults() {
    return this.definitionsValue[this.inheritTarget.value] || this.fallbackValue
  }
}
