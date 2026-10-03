import { Controller } from "@hotwired/stimulus"

// Client-side convenience for the server-derived resend interval: counts the
// button label down and enables it when the interval elapses. The deadline is
// wall-clock anchored so background-tab timer throttling cannot stall it, and
// the server remains authoritative — a losing resend simply re-renders the
// disabled state.
export default class extends Controller {
  static targets = ["button"]
  static values = { seconds: Number }

  connect() {
    this.deadline = Date.now() + this.secondsValue * 1000
    this.timer = setInterval(() => this.tick(), 1000)
    this.tick()
  }

  disconnect() {
    clearInterval(this.timer)
  }

  tick() {
    const remaining = Math.ceil((this.deadline - Date.now()) / 1000)
    if (remaining > 0) {
      this.buttonTarget.textContent = `${this.label()} in ${remaining}s`
    } else {
      this.buttonTarget.textContent = this.label()
      this.buttonTarget.disabled = false
      clearInterval(this.timer)
    }
  }

  label() {
    return this.buttonTarget.dataset.countdownLabel
  }
}
