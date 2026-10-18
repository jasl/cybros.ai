import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["choice", "fields"]

  connect() {
    this.change()
  }

  change() {
    for (const fields of this.fieldsTargets) {
      const selected = fields.dataset.choice === this.choiceTarget.value
      fields.hidden = !selected
      fields.disabled = !selected
    }
  }
}
