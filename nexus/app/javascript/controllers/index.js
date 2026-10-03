// Maintained BY HAND — do not run ./bin/rails stimulus:manifest:update: it
// would re-register the ui/ controllers under "ui--*" identifiers and
// silently disconnect every data-controller reference in the views.
//
// Shell-level UI controllers live under ./ui and keep their short stable identifiers;
// page-owned controllers register beside
// their pages at the top level.

import { application } from "./application"

import ClipboardController from "./ui/clipboard_controller"
application.register("clipboard", ClipboardController)

import CountdownController from "./ui/countdown_controller"
application.register("countdown", CountdownController)

import DropdownController from "./ui/dropdown_controller"
application.register("dropdown", DropdownController)

import SidebarController from "./ui/sidebar_controller"
application.register("sidebar", SidebarController)

import ThemeController from "./ui/theme_controller"
application.register("theme", ThemeController)

import ProviderAuthorizationController from "./provider_authorization_controller"
application.register("provider-authorization", ProviderAuthorizationController)

import SetupSecretController from "./setup_secret_controller"
application.register("setup-secret", SetupSecretController)
