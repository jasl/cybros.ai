import { el } from "../../kernel/dom.js";
import { t, statusText } from "../../kernel/i18n.js";
import { alert, button, glyphMark, menuButton, namedMark } from "../../primitives/index.js";

// The daemon resolves its implicit own Runner and any saved selection. Keep a
// deliberate browser choice, but never guess a default from inventory order.
export function runnerChoice(runners, { current, defaultRunner, edited }) {
  const selected = edited ? current : defaultRunner || runners.find((row) => row.selected)?.public_id || current;
  return runners.find((row) => row.public_id === selected) || null;
}

const runnerName = (row) => [row.display_name || row.public_id, row.own ? t("hero.this_machine") : null,
  row.presence ? statusText(row.presence) : null].filter(Boolean).join(" · ");

function runnerLabel({ runners, runner, choicesError }) {
  if (runners === null) return t("hero.loading_runners");
  const chosen = runners.find((row) => row.public_id === runner);
  if (chosen) return chosen.display_name || chosen.public_id;
  if (!runners.length && choicesError) return t("hero.runners_unavailable");
  return t("hero.choose_a_runner");
}

// What a new conversation starts from: the composer, its Runner selection,
// and the setup notice while connection, model or a plugin needs attention.
export function createHero({ conversations, shell }) {
  const get = () => conversations.state.get();
  const composerSlot = el("div", { class: "hero__composer" });
  const failure = alert({ tone: "error" });
  const noticeTitle = el("p", { class: "hero__notice-title" });
  const noticeText = el("p", { class: "hero__notice-text", text: t("setup.finish_setup") });
  const noticeAction = button({ label: t("setup.open_settings"), size: "sm", onClick: () => openSetup() });
  const notice = el("div", { class: "hero__notice", role: "status", hidden: true },
    el("div", { class: "hero__notice-copy" }, noticeTitle, noticeText), noticeAction);
  const runner = menuButton({ label: t("hero.loading_runners"), icon: "terminal", items: () => {
    const { runners, runner: chosen, choicesError } = get();
    if (runners === null) return [{ type: "item", label: t("hero.loading_runners"), disabled: true }];
    if (!runners.length) return [{ type: "item", label: choicesError ? t("hero.runners_unavailable") : t("hero.no_runners"), disabled: true }];
    return runners.map((row) => ({ type: "radio", label: runnerName(row), checked: row.public_id === chosen,
      onSelect: () => conversations.setRunner(row.public_id) }));
  } });
  // Who will answer: rho, or the bot the sidebar's group named — its mark
  // and its name take the title.
  const markSlot = el("span", { class: "hero__mark" }, namedMark({ own: true, size: "lg" }));
  const title = el("h2", { class: "hero__title", text: t("hero.title") });
  const element = el("div", { class: "hero" },
    el("div", { class: "hero__column" }, markSlot, title,
      notice, failure.element, composerSlot,
      el("div", { class: "hero__location", role: "group", "aria-label": t("hero.runner") },
        el("span", { class: "hero__location-label", text: t("hero.runner") }), runner.element)));

  // Main's Preset supplies its model; the connection is in General.
  function openSetup() {
    const progress = shell.setup.progress();
    if (progress.step === "plugin") shell.openPlugin(progress.plugin);
    else if (progress.step === "model") shell.settings.open("presets", "main");
    else shell.settings.open("general");
  }

  function paintSetup() {
    const progress = shell.setup.progress();
    notice.hidden = progress.ready || !shell.setup.state.get().status;
    noticeTitle.textContent = progress.title;
    noticeText.hidden = progress.step === "plugin";
    noticeAction.querySelector(".btn__label").textContent = progress.step === "plugin" ? t("hero.open_plugin")
      : progress.step === "model" ? t("presets.title") : t("setup.open_settings");
  }

  let shownBot = null;
  function paintBot(value) {
    const bot = value.agent ? shell.bots.byId(value.agent) : null;
    const key = bot ? `${bot.public_id}:${bot.display_name || bot.name}` : null;
    if (key === shownBot) return;
    shownBot = key;
    markSlot.replaceChildren(bot ? glyphMark({ glyph: "bot", size: "lg" }) : namedMark({ own: true, size: "lg" }));
    title.textContent = bot ? t("hero.title_with_bot", { bot: bot.display_name || bot.name }) : t("hero.title");
  }

  function paint(value) {
    paintBot(value);
    runner.update({ label: runnerLabel(value) });
    runner.element.setAttribute("aria-label", t("hero.runner_label", { runner: runnerLabel(value) }));
    if (value.error && !value.id) failure.show(value.error); else failure.hide();
  }

  const stops = [
    conversations.state.subscribe(paint, { immediate: true }),
    shell.setup.state.subscribe(paintSetup, { immediate: true }),
    shell.inventory.state.subscribe(paintSetup),
    shell.bots.state.subscribe(() => paintBot(get())),
  ];
  return {
    element, composerSlot,
    dispose() { for (const stop of stops) stop(); runner.dispose(); },
  };
}
