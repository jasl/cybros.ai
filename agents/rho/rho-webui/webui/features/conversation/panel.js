import { el } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { createHeader } from "./header.js";
import { createTranscript } from "./transcript.js";
import { createSeat } from "./seat.js";
import { createComposer } from "./composer.js";
import { createHero } from "./hero.js";

// The `main` conversation panel. One composer instance serves both layouts:
// the hero while composing a new conversation, the sticky seat under the
// transcript once one is open. The panel is retained while another `main`
// panel shows, so its scroll position, drafts and streams survive.
export function conversationPanel({ conversations, shell }) {
  const header = createHeader({ conversations, shell });
  const scroller = el("div", { class: "conversation__scroller", role: "region", tabindex: "0", "aria-label": t("conversation.history") });
  const transcript = createTranscript({ conversations, scroller });
  const seat = createSeat({ conversations, nexusUrl: () => shell.setup.state.get().document?.nexus?.public_url });
  const hero = createHero({ conversations, shell });
  const composer = createComposer({ conversations });
  seat.element.prepend(transcript.jump);
  const thread = el("div", { class: "conversation__thread" }, transcript.element, seat.element);
  const element = el("section", { class: "conversation", "aria-label": t("conversation.label") }, header.element, scroller);
  let layout = null;

  function place(value) {
    const next = value.id ? "thread" : "hero";
    if (next === layout) return;
    layout = next;
    if (next === "hero") { scroller.replaceChildren(hero.element); hero.composerSlot.append(composer.element); }
    else { scroller.replaceChildren(thread); seat.composerSlot.append(composer.element); }
    element.dataset.layout = next;
  }

  const stop = conversations.state.subscribe(place, { immediate: true });
  return {
    element,
    update() {},
    dispose() {
      stop();
      for (const part of [composer, hero, seat, transcript, header]) part.dispose();
    },
  };
}
