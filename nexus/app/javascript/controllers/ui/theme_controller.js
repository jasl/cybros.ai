import { Controller } from "@hotwired/stimulus"

// Appearance switcher in the user menu. "light" and "dark" pin a daisyUI
// theme via the html data-theme attribute; "system" removes it so the
// prefers-color-scheme themes apply. The cookie lets the server render the
// chosen theme on the next request without a flash.
export default class extends Controller {
  static targets = ["choice"]

  choose(event) {
    const value = event.params.value
    document.cookie = `theme=${value}; path=/; max-age=31536000; samesite=lax`
    if (value === "system") {
      delete document.documentElement.dataset.theme
    } else {
      document.documentElement.dataset.theme = value
    }
    this.choiceTargets.forEach((button) => {
      const chosen = button === event.currentTarget
      button.setAttribute("aria-pressed", chosen ? "true" : "false")
      // base-300 stays visible on the base-200 popup in both themes (daisyUI's
      // btn-active resolves to base-200 and would vanish against it).
      button.classList.toggle("bg-base-300", chosen)
      button.classList.toggle("border-base-300", chosen)
      button.classList.toggle("btn-ghost", !chosen)
    })
  }
}
