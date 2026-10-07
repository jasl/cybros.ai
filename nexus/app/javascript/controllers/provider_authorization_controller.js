import { Controller } from "@hotwired/stimulus"

// Each pending response schedules one read of the same authorization session.
// A terminal response has no controller, so it stops refreshing naturally.
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.timer = setTimeout(() => this.refresh(), 2500)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  refresh() {
    const frame = this.element.closest("turbo-frame")
    if (frame.hasAttribute("src")) {
      frame.reload()
    } else {
      frame.src = this.urlValue
    }
  }
}
