// A select's options: the empty choice, the directory's rows, then each kept
// value the directory does not list (the saved one, the one being edited),
// so a saved reference stays visible and selectable. While the directory is
// unknown a kept value shows as itself, since nothing says it is gone.
function choices(empty, rows, kept, unlisted) {
  const listed = rows || [];
  const extra = [...new Set(kept)].filter((value) => value && !listed.some((row) => row.value === value))
    .map((value) => ({ value, label: rows ? unlisted(value) : value }));
  return [empty, ...listed, ...extra];
}

export function projectChoices(projects, kept, t) {
  const rows = projects && projects.map((row) => ({ value: row.id, label: `${row.title || row.id} · ${row.workspaceRoot}` }));
  return choices({ value: "", label: t("project.not_set") }, rows, kept, (id) => t("project.unavailable", { id }));
}

// An agent that is not ready stays listed with the service's reason, but
// cannot be chosen.
export function agentChoices(providers, kept, t) {
  const rows = providers && providers.map((row) => ({
    value: row.agent, disabled: !row.available,
    label: [row.agent, row.harness === row.agent ? null : row.harness, row.available ? null : row.reason].filter(Boolean).join(" · "),
  }));
  return choices({ value: "", label: t("agent.automatic") }, rows, kept, (agent) => t("agent.unavailable", { agent }));
}
