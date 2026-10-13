import { el, icon, placeChildren } from "../../kernel/dom.js";
import { t } from "../../kernel/i18n.js";
import { markdown } from "../../kernel/markdown.js";
import { isTerminal } from "../../kernel/format.js";
import { preserveArtifacts } from "../../kernel/artifacts.js";
import { button, disclosure, spinner } from "../../primitives/index.js";
import { turnRow } from "./turn.js";
import { activityDisclosure } from "./activity.js";

const BOTTOM_TOLERANCE = 2;
const PREVIEW = 160;

// The streamed answer of the running turn: reasoning folded to its latest
// line, the text so far, and the working status under it.
function createLive() {
  const text = el("div", { class: "markdown" });
  const thinking = disclosure({ title: t("transcript.reasoning"), icon: "thought", attrs: { class: "disclosure live__reasoning" } });
  const thought = el("p", { class: "live__thought" });
  thinking.body.append(thought);
  const status = el("p", { class: "live__status" }, spinner(), el("span", { class: "shimmer", text: t("transcript.working") }));
  const element = el("article", { class: "turn turn--assistant turn--live", "aria-label": t("transcript.current_response"), hidden: true },
    thinking.element, text, status);
  let shown = null;
  return {
    element,
    paint(value) {
      const settled = value.turns.some((turn) => turn.public_id === value.snapshot?.turn && isTerminal(turn.status));
      element.hidden = !value.detail?.active_turn_public_id || settled || value.access !== "ready";
      if (element.hidden) return;
      if (value.live !== shown) { shown = value.live; text.replaceChildren(markdown(value.live)); }
      text.hidden = !value.live;
      thinking.element.hidden = !value.reasoning;
      if (thought.textContent !== value.reasoning) thought.textContent = value.reasoning;
      thinking.setSummary(value.reasoning.trim().split("\n").at(-1)?.slice(-PREVIEW) || "");
    },
  };
}

// Durable turns keyed by id: a turn is rebuilt only when its document
// changes, keeps its open disclosures and pending artifact reads, and nodes
// move with the fewest DOM operations so focus and scroll stay put.
export function createTranscript({ conversations, scroller }) {
  const more = button({ label: t("transcript.load_earlier"), variant: "ghost", size: "sm", onClick: () => loadOlder() });
  more.classList.add("transcript__more");
  const turns = el("div", { class: "transcript__turns" });
  const empty = el("p", { class: "transcript__empty", text: t("transcript.empty"), hidden: true });
  const live = createLive();
  const jump = el("button", { type: "button", class: "jump round", "aria-label": t("transcript.jump"), "data-tip": t("transcript.jump"), hidden: true,
    onclick: () => { toEnd(); jump.hidden = true; } }, icon("arrow-down"));
  const element = el("div", { class: "transcript" }, more, turns, empty, live.element);
  const nodes = new Map();
  let artifacts = null;
  let shownId;
  let shownTurns = null;
  let shownActive = null;
  let frame = null;
  let following = true;
  let lastTop = scroller.scrollTop;
  let touchY = null;

  const atBottom = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= BOTTOM_TOLERANCE;
  const toEnd = () => {
    following = true;
    scroller.scrollTop = scroller.scrollHeight;
    lastTop = scroller.scrollTop;
    jump.hidden = true;
  };
  const onScroll = () => {
    const top = scroller.scrollTop;
    // Folding a disclosure can clamp scrollTop while still at the end.
    if (top < lastTop && !atBottom()) following = false;
    else if (top > lastTop && atBottom()) following = true;
    lastTop = top;
    jump.hidden = atBottom();
  };
  // Reading intent wins before the next streamed frame, even when one small
  // upward gesture still leaves the viewport close to the last line.
  const onWheel = (event) => { if (event.deltaY < 0) following = false; };
  const onTouchStart = (event) => { touchY = event.touches[0]?.clientY ?? null; };
  const onTouchMove = (event) => {
    const next = event.touches[0]?.clientY ?? null;
    if (touchY !== null && next !== null && next > touchY) following = false;
    touchY = next;
  };
  const onKey = (event) => {
    if (event.target.closest("input, textarea, select, [contenteditable=true]")) return;
    if (["ArrowUp", "PageUp", "Home"].includes(event.key) || event.key === " " && event.shiftKey) following = false;
  };
  scroller.addEventListener("scroll", onScroll);
  scroller.addEventListener("wheel", onWheel, { passive: true });
  scroller.addEventListener("touchstart", onTouchStart, { passive: true });
  scroller.addEventListener("touchmove", onTouchMove, { passive: true });
  scroller.addEventListener("keydown", onKey);

  // Another conversation: its rows, open disclosures and object URLs go.
  function reset(id) {
    artifacts?.dispose();
    artifacts = conversations.artifactOpener();
    for (const entry of nodes.values()) entry.node.remove();
    nodes.clear();
    shownId = id; shownTurns = null; shownActive = null;
    following = true;
    jump.hidden = true;
  }

  function paintTurns(rows, active) {
    shownTurns = rows; shownActive = active;
    const order = [];
    const alive = new Set();
    const activity = (runId, turnId) => activityDisclosure(runId, turnId, { rounds: conversations.rounds, openTask: conversations.openTask, artifacts });
    for (const turn of rows) {
      const signature = JSON.stringify([turn, turn.public_id === active]);
      let entry = nodes.get(turn.public_id);
      if (!entry || entry.signature !== signature) {
        const node = turnRow(turn, { active: turn.public_id === active, artifacts, activity });
        if (entry) {
          const open = new Set([...entry.node.querySelectorAll("details[open]")].map((details) => details.dataset.disclosure));
          preserveArtifacts(entry.node, node);
          for (const details of node.querySelectorAll("details")) if (open.has(details.dataset.disclosure)) details.open = true;
          entry.node.replaceWith(node);
        }
        entry = { node, signature };
        nodes.set(turn.public_id, entry);
      }
      alive.add(turn.public_id);
      order.push(entry.node);
    }
    for (const [id, entry] of nodes) if (!alive.has(id)) { entry.node.remove(); nodes.delete(id); }
    placeChildren(turns, order);
    if (following) toEnd();
  }

  // Deltas arrive faster than frames; the live row repaints once per frame.
  function scheduleLive() {
    if (frame !== null) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      live.paint(conversations.state.get());
      if (following) toEnd();
      else jump.hidden = atBottom();
    });
  }

  async function loadOlder() {
    const height = scroller.scrollHeight;
    const top = scroller.scrollTop;
    const id = shownId;
    following = false;
    more.disabled = true;
    try {
      await conversations.loadOlder();
      if (id === shownId) {
        scroller.scrollTop = top + scroller.scrollHeight - height;
        lastTop = scroller.scrollTop;
      }
    } finally { more.disabled = false; }
  }

  function paint(value) {
    if (value.id !== shownId) reset(value.id);
    const active = value.detail?.active_turn_public_id || null;
    if (value.turns !== shownTurns || active !== shownActive) paintTurns(value.turns, active);
    more.hidden = !value.older;
    empty.hidden = !value.id || value.turns.length > 0 || value.access === "loading";
    scheduleLive();
  }

  const stop = conversations.state.subscribe(paint, { immediate: true });
  return {
    element, jump,
    dispose() {
      stop();
      if (frame !== null) cancelAnimationFrame(frame);
      scroller.removeEventListener("scroll", onScroll);
      scroller.removeEventListener("wheel", onWheel);
      scroller.removeEventListener("touchstart", onTouchStart);
      scroller.removeEventListener("touchmove", onTouchMove);
      scroller.removeEventListener("keydown", onKey);
      artifacts?.dispose();
    },
  };
}
