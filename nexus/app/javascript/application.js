// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import { Turbo } from "@hotwired/turbo-rails"
import "./controllers"
import { confirmWithDialog } from "./confirm_dialog"

Turbo.config.forms.confirm = confirmWithDialog

// A capability page can submit with Turbo without disclosing its URL.
// OAuth authorization continues as a full browser navigation across origins.
Turbo.StreamActions.sso_navigate = function () {
  const destination = new URL(this.getAttribute("url"))
  if (["https:", "http:"].includes(destination.protocol)) window.location.assign(destination.href)
}
