// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import { Turbo } from "@hotwired/turbo-rails"
import "./controllers"
import { confirmWithDialog } from "./confirm_dialog"

Turbo.config.forms.confirm = confirmWithDialog
