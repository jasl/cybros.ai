import { Controller } from "@hotwired/stimulus"

// Closes an open <details class="dropdown"> on outside click or Escape,
// giving the disclosure element the dismissal behavior a menu needs. The
// dropdown still opens and closes without JavaScript.
export default class extends Controller {
  close(event) {
    if (!this.element.open) {
      return
    }
    if (event.type === "click" && this.element.contains(event.target)) {
      return
    }
    const focusWasInside = this.element.contains(document.activeElement)
    this.element.open = false
    if (focusWasInside) {
      this.element.querySelector("summary")?.focus()
    }
  }
}
