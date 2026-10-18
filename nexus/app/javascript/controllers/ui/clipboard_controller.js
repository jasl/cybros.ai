import { Controller } from "@hotwired/stimulus"

// Inputs and rendered code remain selectable by hand without JavaScript.
export default class extends Controller {
  static targets = ["source", "button"]
  static values = { copied: String }

  connect() {
    this.copyLabel = this.buttonTarget.textContent
  }

  copy() {
    if (navigator.clipboard) {
      const text = this.sourceTarget.value ?? this.sourceTarget.textContent
      navigator.clipboard.writeText(text).then(
        () => this.showCopied(),
        () => this.copyFromSelection(),
      )
    } else {
      this.copyFromSelection()
    }
  }

  copyFromSelection() {
    if (this.sourceTarget.select) {
      this.sourceTarget.select()
    } else {
      const range = document.createRange()
      range.selectNodeContents(this.sourceTarget)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    }
    if (document.execCommand("copy")) this.showCopied()
  }

  showCopied() {
    this.buttonTarget.textContent = this.copiedValue
    setTimeout(() => { this.buttonTarget.textContent = this.copyLabel }, 1500)
  }
}
