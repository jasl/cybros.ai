import { t } from "../../kernel/i18n.js";
import { Submissions } from "../../kernel/submissions.js";
import { iconButton, panelRow } from "../../primitives/index.js";
import { schedulesPanel } from "./schedules.js";
import { jobsPage } from "./page.js";

const PANEL = "schedules";

function scheduleButton(shell, initialProps) {
  const element = iconButton({ icon: "clock", label: t("common.scheduled_jobs"), onClick: () => shell.dock.open("schedules") });
  const paint = ({ conversation }) => {
    element.hidden = !conversation.id;
    element.disabled = conversation.access === "unavailable";
  };
  paint(initialProps);
  return { element, update: paint };
}

export function register(ui, shell) {
  // Creation keys outlive the tab: an uncertain create keeps its key for a
  // manual retry of the same payload until the page reloads.
  const creates = new Submissions();
  ui.slots.register("dock.tab", { key: "schedules", title: () => t("common.scheduled_jobs"), description: () => t("schedules.guide"), icon: "clock" },
    (props) => schedulesPanel(shell, props, { creates }));
  ui.slots.register("conversation.header.utilities", { id: "schedules", order: 20 }, (props) => scheduleButton(shell, props));
  // The workspace overview: every conversation's jobs on one page, reached
  // from the sidebar beside Plugins.
  ui.slots.register("main", { key: PANEL }, () => jobsPage(shell));
  ui.slots.register("sidebar.panellist", { id: PANEL, order: 5 }, (props) => {
    const row = panelRow({ key: PANEL, icon: "clock", label: t("common.scheduled_jobs"), navigate: ui.navigate });
    row.update(props);
    return row;
  });
}
