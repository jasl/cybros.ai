import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["secret"]

  connect() {
    const fragment = new URLSearchParams(window.location.hash.slice(1))
    if (fragment.has("setup_secret")) {
      window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search)
      if (this.hasSecretTarget) this.secretTarget.value = fragment.get("setup_secret")
    }
  }

  submitted({ detail: { success } }) {
    // The permanent password input survives validation errors only in this page.
    if (success && this.hasSecretTarget) this.secretTarget.value = ""
  }
}
