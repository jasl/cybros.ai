import { Controller } from "@hotwired/stimulus"

// Only trusted controls are added after the server has sanitized the content.
export default class extends Controller {
  static targets = ["body"]
  static values = { copy: String, copied: String }

  connect() {
    for (const code of this.bodyTarget.querySelectorAll("pre > code")) {
      const pre = code.parentElement
      if (pre.dataset.controller === "clipboard") continue
      pre.dataset.controller = "clipboard"
      pre.dataset.clipboardCopiedValue = this.copiedValue
      code.dataset.clipboardTarget = "source"
      const button = document.createElement("button")
      button.type = "button"
      button.className = "btn btn-ghost btn-xs mb-2 block"
      button.textContent = this.copyValue
      button.dataset.clipboardTarget = "button"
      button.dataset.action = "clipboard#copy"
      pre.prepend(button)
    }
  }
}
