// One fact of the status card: its name, what the read found, and a line of
// detail beneath the name.
function fact(el, label) {
  const value = el("div", { class: "row row--wrap" });
  const detail = el("div", { class: "settings-row__description wrap-anywhere", hidden: true });
  const element = el("div", { class: "settings-row" },
    el("div", { class: "settings-row__text" }, el("span", { class: "settings-row__label", text: label }), detail), value);
  return {
    element,
    show(nodes, about = null) {
      value.replaceChildren(...nodes);
      detail.replaceChildren(...(about ? [about] : []));
      detail.hidden = !about;
    },
  };
}

// Where the service runs, whether it answered this read and what setup
// still needs; then only what needs attention — a bearer that is not
// saved, a native program a local service cannot find on rho's PATH.
// `status` describes the running plugin instance.
export function statusCard(ui, t, { level, refresh }) {
  const { el, primitives: p } = ui;
  const loading = el("p", { class: "text-secondary", role: "status", text: t("status.loading") });
  const location = fact(el, t("status.location"));
  const connection = fact(el, t("status.connection"));
  const bearer = fact(el, t("status.bearer"));
  const setup = fact(el, t("status.setup"));
  const programs = fact(el, t("status.programs"));
  const facts = el("div", { hidden: true }, location.element, connection.element, bearer.element, setup.element, programs.element);
  const card = p.section({ title: t("status.title"), level, actions: [p.iconButton({ icon: "refresh", label: t("status.refresh"), onClick: refresh })] });
  card.body.append(loading, facts);

  function paint({ status, service }) {
    loading.hidden = true;
    facts.hidden = false;
    location.show([el("span", { class: "strong", text: status.server === "local" ? t("server.local") : t("server.host") })],
      status.url ? el("span", { class: "mono", text: status.url }) : t("status.no_url"));
    connection.show([p.stateDot({ tone: service.reachable ? "ok" : "bad" }),
      el("span", { text: service.reachable ? t("status.connected") : t("status.unavailable") })],
    service.reachable ? t("status.protocol", { version: service.orchestration_protocol }) : service.error);
    // A missing bearer, never the bearer; a saved one is the connection card's hint to say.
    bearer.element.hidden = status.bearer === "saved";
    bearer.show([p.stateDot({ tone: "warn" }), el("span", { text: t("status.bearer_none") })]);
    setup.show([p.stateDot({ tone: status.configured ? "ok" : "warn" }),
      el("span", { text: status.configured ? t("status.ready") : t("status.needs_setup") })],
    status.issues.length ? el("ul", { class: "stack stack--tight" }, status.issues.map((issue) => el("li", { text: issue }))) : null);
    const missing = Object.entries(status.installed || {}).filter(([, found]) => !found).map(([program]) => program);
    programs.element.hidden = !missing.length;
    if (missing.length) programs.show(missing.map((program) => p.tag({ tone: "warning", text: t("status.program_missing", { program }) })), t("status.programs_hint"));
  }

  return {
    element: card.element, body: card.body, paint,
    // A first read that failed leaves nothing to show; the alert says why.
    failed() { loading.hidden = true; },
  };
}
