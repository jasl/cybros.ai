import { Controller } from "@hotwired/stimulus"

// Show whole seconds, retaining the exact report boundary until someone edits
// the control, then submit their chosen UTC time.
export default class extends Controller {
  static targets = ["datetime"]

  sync() {
    for (const input of this.datetimeTargets) {
      const unchanged = Date.parse(`${input.value}Z`) === Date.parse(`${input.dataset.original}Z`)
      this.element.elements.namedItem(input.dataset.boundary).value = unchanged
        ? input.dataset.exact : input.value ? `${input.value}Z` : ""
    }
  }
}
