import { el } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";

const ARC_START = 72;
const ARC_END = 288;

// The framework-free boot page: a spinner whose arc grows as modules settle,
// per-module lines, and a failure that stays readable instead of a blank
// page. It exists in the static HTML before any script runs.
export function createBoot(element) {
  const wordmark = el("p", { class: "boot__wordmark", text: t("brand.rho").toUpperCase() });
  const hint = el("p", { class: "boot__hint", text: t("boot.loading_plugins") });
  const lines = el("ul", { class: "boot__lines" });
  element.append(wordmark, hint, lines);
  let unsubscribe = null;

  function paint(states) {
    const rows = [...states.values()];
    const settled = rows.filter((row) => row.status !== "loading").length;
    const arc = rows.length ? ARC_START + (ARC_END - ARC_START) * (settled / rows.length) : ARC_START;
    element.style.setProperty("--boot-arc", `${Math.round(arc)}deg`);
    lines.replaceChildren(...rows.filter((row) => row.status !== "ready").map((row) => el("li", {
      class: `boot__line${row.status === "failed" ? " boot__line--failed" : ""}`,
      text: row.status === "failed" ? t("boot.module_failed", { name: row.name }) : t("boot.module_loading", { name: row.name }),
    })));
  }

  return {
    watch(states) {
      unsubscribe?.();
      unsubscribe = states.subscribe(paint, { immediate: true });
    },
    fail(title, details = []) {
      unsubscribe?.();
      element.classList.add("boot--failed");
      element.querySelector(".boot__spinner")?.remove();
      hint.textContent = title;
      hint.className = "boot__failure";
      lines.replaceChildren(...details.map((detail) => el("li", { class: "boot__line boot__line--failed mono", text: detail })));
    },
    hide() {
      unsubscribe?.();
      element.remove();
    },
  };
}
