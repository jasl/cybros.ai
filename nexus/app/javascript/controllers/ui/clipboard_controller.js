import { Controller } from "@hotwired/stimulus"

// Copies the source input's value and gives brief button feedback. The
// readonly input remains selectable by hand, so copying works without
// JavaScript too.
export default class extends Controller {
  static targets = ["source", "button"]
  static values = { copied: String }

  connect() {
    this.copyLabel = this.buttonTarget.textContent
  }

  copy() {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(this.sourceTarget.value).then(
        () => this.showCopied(),
        () => this.copyFromSelection(),
      )
    } else {
      this.copyFromSelection()
    }
  }

  copyFromSelection() {
    this.sourceTarget.select()
    if (document.execCommand("copy")) this.showCopied()
  }

  showCopied() {
    this.buttonTarget.textContent = this.copiedValue
    setTimeout(() => { this.buttonTarget.textContent = this.copyLabel }, 1500)
  }
}
