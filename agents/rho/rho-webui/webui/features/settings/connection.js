import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, disclosure, field, input, section } from "../../primitives/index.js";

export function connectionCard(shell, initialProps) {
  let props = initialProps;
  const keys = {
    access_token: input({ name: "access_token", type: "password", autocomplete: "off" }),
    executor_access_token: input({ name: "executor_access_token", type: "password", autocomplete: "off" }),
  };
  const labels = { access_token: t("connection.access_token"), executor_access_token: t("connection.executor_access_token") };
  const rows = Object.fromEntries(Object.entries(keys).map(([name, control]) =>
    [name, field({ label: labels[name], control })]));
  const submitButton = button({ label: t("connection.import"), variant: "primary", size: "sm", type: "submit" });
  const feedback = alert({ tone: "success" });
  const fields = el("fieldset", { class: "settings-form__fields" }, ...Object.values(rows).map((row) => row.element),
    el("div", { class: "settings-form__actions" }, submitButton));
  const form = el("form", { class: "settings-form", onsubmit: submit }, fields);
  const card = section({ title: t("connection.title"), description: t("connection.description") });
  const details = disclosure({ title: t("connection.enter_keys") });
  details.body.append(form, feedback.element);
  card.body.append(details.element);

  async function submit(event) {
    event.preventDefault();
    fields.disabled = true; feedback.hide();
    try {
      const body = Object.fromEntries(Object.keys(keys).map((name) => [name, keys[name].value]));
      if (Object.values(body).some((value) => !value.trim())) {
        feedback.show(t("connection.required"), "error");
        return;
      }
      await shell.call("/connection/api_keys", { method: "POST", body });
      for (const control of Object.values(keys)) control.value = "";
      await props.refresh();
      feedback.show(t("connection.imported"), "success");
    } catch (error) {
      for (const control of Object.values(keys)) control.value = "";
      if (error.name !== "AbortError" && error.status !== 401) feedback.show(error.message, "error");
    } finally { fields.disabled = false; }
  }

  return { element: card.element, update(next) { props = next; } };
}
