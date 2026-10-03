import { Controller } from "@hotwired/stimulus"

// Copies the source input's value and gives brief button feedback. The
// readonly input remains selectable by hand, so copying works without
// JavaScript too.
export default class extends Controller {
  static targets = ["source", "button"]

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
    this.buttonTarget.textContent = "Copied"
    setTimeout(() => { this.buttonTarget.textContent = "Copy" }, 1500)
  }
}
