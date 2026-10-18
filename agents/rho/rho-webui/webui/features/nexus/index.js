import { nexusPage } from "./page.js";

// Nexus: the account's administration — providers and models for every
// agent — as its own page, apart from Settings, which is rho's. The
// sidebar's foot keeps both in reach, below the panels.
export function register(ui, shell) {
  ui.slots.register("main", { key: "nexus" }, () => nexusPage(shell));
}
