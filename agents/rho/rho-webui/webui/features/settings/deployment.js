import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { uuidv7 } from "../../kernel/uuid.js";
import { alert, button, checkbox, field, input, modal, section, tag } from "../../primitives/index.js";

const NEXUS = "/api/v1/admin/deployment";
const MAX_LOG_CHARS = 131072;

export function deploymentSection(shell, props = {}) {
  const rho = upgradeCard(shell, "rho", async (operation, values, signal) => {
    if (operation === "status") return shell.call("/deployment", { signal });
    if (operation === "check") return shell.call("/deployment/check", { method: "POST", body: { tag: values.tag }, signal });
    if (operation === "upgrade") return shell.call("/deployment/upgrade", { method: "POST", body: values.pending, signal });
    return shell.call(`/deployment/log?operation_id=${encodeURIComponent(values.id)}&cursor=${encodeURIComponent(values.cursor || "")}`, { signal });
  }, props);
  const nexus = upgradeCard(shell, "nexus", async (operation, values, signal) => {
    if (operation === "status") return (await shell.nexus.request(NEXUS, { signal })).deployment;
    if (operation === "check") return (await shell.nexus.request(`${NEXUS}/release_check`, { method: "POST", body: { release_check: { tag: values.tag, backup: values.backup } }, timeout: 120, signal })).deployment;
    if (operation === "upgrade") return (await shell.nexus.request(`${NEXUS}/upgrades`, { method: "POST", body: { candidate: values.pending.candidate, backup: values.pending.backup }, headers: { "Idempotency-Key": values.pending.idempotency_key }, signal })).upgrade;
    return (await shell.nexus.request(`${NEXUS}/upgrades/${encodeURIComponent(values.id)}/log?cursor=${encodeURIComponent(values.cursor || "")}`, { signal })).log;
  }, props);
  return {
    element: el("div", { class: "settings-section" }, rho.element, nexus.element),
    update(next) { rho.update(next); nexus.update(next); },
    dispose() { rho.dispose(); nexus.dispose(); },
  };
}

function upgradeCard(shell, target, request, initialProps) {
  const name = t(`brand.${target}`);
  const storageKey = `rho.deployment.pending.${target}`;
  let disposed = false;
  let visible = initialProps.visible !== false;
  let busy = false;
  let data = null;
  let choice = null;
  let operation = null;
  let cursor = null;
  let logText = "";
  let pending = readPending();
  let timer;
  let controller;
  let confirmation;
  let access = null;

  const notice = alert();
  const release = input({ name: `${target}_release`, placeholder: "latest", mono: true, attrs: { maxlength: "10" } });
  const backup = checkbox({ name: `${target}_backup`, label: t("deployment.backup"), checked: pending?.backup ?? true, onChange: changed });
  backup.element.hidden = target !== "nexus";
  const facts = el("dl", { class: "settings-facts" });
  const checks = el("div", { class: "upgrade-checks" });
  const help = el("p", { class: "field__hint" });
  const progress = el("div", { class: "upgrade-progress", hidden: true });
  const log = el("pre", { class: "upgrade-log", tabindex: "0", "aria-label": t("deployment.log", { name }), hidden: true });
  const check = button({ label: t("deployment.check"), onClick: () => inspect() });
  const upgrade = button({ label: t("deployment.upgrade", { name }), variant: "primary", disabled: true, onClick: confirm });
  const retry = button({ label: t("deployment.retry"), onClick: () => submit(), attrs: { hidden: true } });
  const refresh = button({ label: t("common.refresh"), onClick: () => load() });
  const signIn = button({ label: t("settings.sign_in_with_nexus"), onClick: () => shell.signIn(), attrs: { hidden: true } });
  const card = section({ title: name, description: target === "rho" ? t("deployment.rho_description") : t("deployment.nexus_description") });
  card.element.dataset.upgradeTarget = target;
  const selector = field({ label: t("deployment.release"), control: release, hint: t("deployment.release_hint") });
  card.body.append(notice.element, help, facts, selector.element, backup.element, checks,
    el("div", { class: "row row--wrap" }, check, upgrade, retry, refresh, signIn), progress, log);
  release.addEventListener("input", changed);

  function readPending() {
    try {
      const value = JSON.parse(sessionStorage.getItem(storageKey));
      return value?.idempotency_key && value.candidate?.release && Array.isArray(value.candidate.images) ? value : null;
    } catch { return null; }
  }
  function savePending() {
    try {
      if (pending) sessionStorage.setItem(storageKey, JSON.stringify(pending));
      else sessionStorage.removeItem(storageKey);
    } catch { /* The page still retains the exact request until it closes. */ }
  }
  function changed() { choice = null; paint(); }
  function guidance() {
    if (access === "sign_in") return t("deployment.sign_in");
    if (access === "administrator") return t("deployment.administrator");
    if (data?.supported !== false) return "";
    if (target === "nexus") return t("deployment.nexus_unsupported");
    if (data.mode === "container") return t("deployment.container_unsupported");
    if (data.mode === "installed") return t("deployment.installed_unsupported");
    return t("deployment.checkout_unsupported");
  }
  function adopt(next) {
    if (!next) return;
    if (operation?.id !== next.id) { cursor = null; logText = ""; }
    operation = next;
    if (pending && next.idempotency_key === pending.idempotency_key) { pending = null; savePending(); }
  }
  function paint() {
    const supported = data?.supported === true && !access;
    const running = operation?.status === "running";
    selector.element.hidden = !supported;
    backup.element.hidden = !supported || target !== "nexus";
    release.disabled = backup.input.disabled = busy || running || !!pending;
    check.hidden = upgrade.hidden = !supported;
    check.disabled = busy || running || !!pending;
    upgrade.disabled = busy || running || !!pending || !choice;
    refresh.disabled = busy;
    retry.hidden = !pending || !!access;
    retry.disabled = busy || running;
    signIn.hidden = access !== "sign_in";
    help.textContent = guidance();
    facts.replaceChildren(...(supported ? [
      el("dt", { text: t("deployment.installed") }), el("dd", { class: "mono", text: data.installed?.release || t("common.not_set") }),
      el("dt", { text: t("deployment.available") }), el("dd", { class: "mono", text: data.candidate?.release || t("deployment.not_checked") }),
    ] : []));
    checks.replaceChildren(...(supported ? (data.preflight?.checks || []).map((item) => el("div", { class: "upgrade-check" },
      el("div", { class: "row row--wrap" }, tag({ tone: item.status === "blocked" ? "danger" : item.status === "warning" ? "warning" : "success", text: t(`deployment.check_${item.status}`, {}, item.status) }), el("strong", { text: item.name })),
      el("p", { text: item.message }), item.next_step ? el("p", { class: "field__hint", text: item.next_step }) : null)) : []));
    progress.hidden = !operation;
    progress.replaceChildren(...(operation ? [
      el("p", { class: "row row--wrap" }, tag({ tone: operation.status === "succeeded" ? "success" : operation.status === "running" ? "info" : "warning", text: t(`deployment.status_${operation.status}`, {}, operation.status) }),
        el("span", { text: t(`deployment.phase_${operation.phase}`, {}, operation.phase) }), el("span", { class: "mono", text: operation.target?.release || "" })),
      el("p", { class: "field__hint", text: t("deployment.receipt", { id: operation.id }) }),
      operation.error ? el("p", { text: operation.error.message }) : null,
      operation.recovery ? el("p", { text: operation.recovery }) : null,
      operation.database_backup ? el("p", { text: operation.database_backup.available
        ? t("deployment.backup_available", { date: operation.database_backup.created_at }) : t("deployment.backup_removed", { date: operation.database_backup.created_at }) }) : null,
    ] : []).filter(Boolean));
    log.textContent = logText;
    log.hidden = !logText;
  }
  function schedule() {
    clearTimeout(timer);
    if (!disposed && visible && !access && (operation?.status === "running" || pending)) timer = setTimeout(() => load(), 2000);
  }
  async function call(action, values = {}) {
    controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), action === "check" ? 140000 : 15000);
    try { return await request(action, values, controller.signal); }
    finally { clearTimeout(deadline); controller = null; }
  }
  function refused(error) {
    if (error.code === "human_login_required" || error.status === 401) access = "sign_in";
    else if (error.status === 403) access = "administrator";
    notice.show(pending ? t("deployment.uncertain") : operation?.status === "running" && (!error.status || error.status >= 500)
      ? t("deployment.reconnecting", { name }) : error.message || t("deployment.unavailable"), pending || operation?.status === "running" ? "warning" : "error");
  }
  async function load() {
    if (disposed || busy || !visible) return;
    busy = true; paint();
    try {
      data = await call("status");
      if (disposed) return;
      access = null;
      adopt(data.active_operation || data.last_operation);
      if (operation) {
        const window = await call("log", { id: operation.id, cursor });
        if (disposed) return;
        logText = (logText + (window.entries || []).map((entry) => entry.text).join("")).slice(-MAX_LOG_CHARS);
        cursor = window.next_cursor;
        adopt(window.operation);
      }
      if (pending) notice.show(t("deployment.uncertain"), "warning"); else notice.hide();
    } catch (error) { if (!disposed) refused(error); }
    finally { busy = false; if (!disposed) { paint(); schedule(); } }
  }
  async function inspect() {
    if (disposed || busy || pending || operation?.status === "running") return;
    choice = null; busy = true; notice.show(t("deployment.checking"), "info"); paint();
    try {
      data = await call("check", { tag: release.value.trim() || "latest", backup: backup.input.checked });
      if (disposed) return;
      access = null;
      if (data.candidate && data.preflight?.ready && (target !== "nexus" || data.preflight.backup === backup.input.checked)) {
        choice = { candidate: { release: data.candidate.release, images: data.candidate.images }, idempotency_key: data.idempotency_key || uuidv7(), ...(target === "nexus" ? { backup: backup.input.checked } : {}) };
      }
      notice.hide();
    } catch (error) { if (!disposed) refused(error); }
    finally { busy = false; if (!disposed) paint(); }
  }
  function confirm() {
    if (!choice || busy || pending) return;
    const selected = choice;
    const accept = button({ label: t("deployment.upgrade", { name }), variant: "primary", onClick: () => {
      confirmation.close();
      if (choice !== selected) return;
      pending = selected; choice = null; savePending(); submit();
    } });
    confirmation = modal({ title: t("deployment.upgrade", { name }), body: el("div", {},
      el("p", { text: target === "rho" ? t("deployment.rho_confirm", { release: selected.candidate.release }) : t("deployment.nexus_confirm", { release: selected.candidate.release }) }),
      target === "nexus" ? el("p", { text: selected.backup ? t("deployment.backup_enabled") : t("deployment.backup_skipped") }) : null),
      actions: [button({ label: t("common.cancel"), onClick: () => confirmation.close() }), accept], onClose: () => confirmation.element.remove() });
    confirmation.open();
  }
  async function submit() {
    if (disposed || busy || !pending) return;
    busy = true; notice.show(t("deployment.submitting"), "info"); paint();
    try {
      const receipt = await call("upgrade", { pending });
      if (disposed) return;
      adopt(receipt); pending = null; savePending(); notice.hide();
    } catch (error) {
      if (!disposed) {
        if (error.status >= 400 && error.status < 500) { pending = null; savePending(); }
        refused(error);
      }
    } finally { busy = false; if (!disposed) { paint(); schedule(); } }
  }

  paint(); load();
  return { element: card.element,
    update({ visible: next = true } = {}) {
      const returning = next && !visible; visible = next;
      if (!visible) clearTimeout(timer);
      else if (returning) load();
    },
    dispose() { disposed = true; clearTimeout(timer); controller?.abort(); confirmation?.close(); confirmation?.element.remove(); },
  };
}
