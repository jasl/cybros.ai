import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { alert, button, checkbox, field, input, section, select } from "../../primitives/index.js";

const MODES = ["", "open", "nexus", "password"];

// What each mode means, in the reader's words.
export function accessLabel(mode) {
  return {
    "": t("access.automatic"), open: t("access.open"), nexus: t("access.nexus"), password: t("access.password"),
  }[mode] ?? mode;
}

// What the gate does right now, from `/auth/status`'s `access`.
export function accessNow(access) {
  if (!access) return "";
  return t("access.right_now", { mode: accessLabel(access.mode) });
}

// Who may open this page once rho is paired: a choice among the gate's
// modes and rho's unlock password. The password is written first through
// its own route, then the mode through the settings, so a `password` mode
// never lands without a password to ask for.
export function accessCard(shell, initialProps) {
  let props = initialProps;
  let dirty = false;
  const now = el("p", { class: "settings-row__description", role: "status" });
  const mode = select({ name: "webui_access", options: MODES.map((value) => ({ value, label: accessLabel(value) })) });
  const password = input({ name: "unlock_password", type: "password", autocomplete: "new-password" });
  const passwordField = field({ label: t("access.unlock_password"), control: password });
  const remove = checkbox({ name: "remove_password", label: t("access.remove_the_saved_password") });
  const save = button({ label: t("access.save"), variant: "primary", size: "sm", type: "submit" });
  const feedback = alert({ tone: "success" });
  const fields = el("fieldset", { class: "settings-form__fields" },
    field({ label: t("access.who_can_open_this_page"), control: mode, hint: t("access.pairing_happens_once") }).element,
    passwordField.element, remove.element, el("div", { class: "settings-form__actions" }, save));
  const form = el("form", { class: "settings-form", onsubmit: submit }, fields);
  const card = section({ title: t("access.title"), description: t("access.description") });
  card.body.append(now, form, feedback.element);
  mode.addEventListener("change", () => { dirty = true; paintFields(); });
  password.addEventListener("input", () => { dirty = true; });
  remove.input.addEventListener("change", () => { dirty = true; });

  const current = () => props.identity?.access || null;
  const saved = () => props.document?.settings?.webui_access || "";

  async function submit(event) {
    event.preventDefault();
    fields.disabled = true; feedback.hide(); passwordField.setError(null);
    try {
      const chosen = mode.value;
      const typed = password.value;
      if (chosen === "password" && !typed && !current()?.password_set) {
        passwordField.setError(t("access.set_a_password_first"));
        return;
      }
      if (typed) await shell.call("/auth/password", { method: "POST", body: { password: typed } });
      if (chosen !== saved()) {
        const answer = await props.save({ webui_access: chosen || null });
        if (!answer) return;
      }
      if (remove.input.checked && chosen !== "password") await shell.call("/auth/password", { method: "POST", body: { password: null } });
      password.value = ""; remove.input.checked = false; dirty = false;
      await props.refresh();
      feedback.show(t("settings.settings_saved_and_active"), "success");
    } catch (error) {
      if (error.name === "AbortError" || error.status === 401) return;
      feedback.show(error.message || t("settings.the_request_failed_your_changes_have_not_been"), "error");
    } finally { fields.disabled = false; paint(); }
  }

  function paintFields() {
    const access = current();
    const asking = mode.value === "password";
    passwordField.element.hidden = !asking;
    passwordField.setHint(access?.password_set ? t("access.leave_blank_to_keep_the_current_password") : t("access.at_least_8_characters"));
    remove.element.hidden = asking || !access?.password_set;
  }

  function paint() {
    now.textContent = accessNow(current());
    if (!dirty) { mode.value = saved(); password.value = ""; remove.input.checked = false; }
    paintFields();
  }

  paint();
  return {
    element: card.element,
    update(next) { props = next; paint(); },
  };
}
