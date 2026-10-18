import { el, uniqueId } from "../kernel/dom.js";
import { t } from "../kernel/i18n.js";
import { iconButton } from "./button.js";

const SIZES = ["sm", "md"];

// A native <dialog>: Escape closes it and focus returns to the opener.
export function modal({ title, body, actions = [], size = "sm", onClose, closable = true, attrs = {} }) {
  if (!SIZES.includes(size)) throw new Error(`Unknown modal size ${size}`);
  const heading = el("h2", { class: "modal__title", id: uniqueId("modal"), text: title });
  const element = el("dialog", { class: `modal modal--${size}`, "aria-labelledby": heading.id, ...attrs },
    el("div", { class: "modal__head" }, heading,
      closable ? iconButton({ icon: "close", label: t("common.close"), onClick: () => element.close() }) : null),
    el("div", { class: "modal__body" }, body),
    actions.length ? el("div", { class: "modal__actions" }, actions) : null);
  element.addEventListener("close", () => onClose?.());
  element.addEventListener("cancel", (event) => { if (!closable) event.preventDefault(); });
  return {
    element,
    open() {
      if (!element.isConnected) document.body.append(element);
      if (!element.open) element.showModal();
    },
    close() { if (element.open) element.close(); },
    setTitle(text) { heading.textContent = text; },
  };
}
