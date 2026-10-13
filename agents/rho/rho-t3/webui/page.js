import { t3Settings } from "./settings.js";

// The sidebar entry that opens the T3 page.
export function t3Row(ui, t, initial) {
  const row = ui.primitives.panelRow({ key: "t3", icon: "terminal", label: t("nav.label"), navigate: ui.navigate });
  row.update(initial);
  return row;
}

// The T3 page: the settings body under its own heading. The shell keeps a
// page it hid, so showing it again reads the status afresh.
export function t3Page(ui, t, initial) {
  const body = t3Settings(ui, t, { level: 2 });
  const view = ui.primitives.page({ title: t("page.title"), description: t("page.description") });
  view.body.append(body.element);
  let visible = initial.visible !== false;
  return {
    element: view.element,
    update(next) {
      const shown = next.visible !== false;
      if (shown && !visible) body.refresh();
      visible = shown;
    },
    dispose() { body.dispose(); },
  };
}
