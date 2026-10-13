import { runnerChoice } from "./hero.js";

// The composer's page-wide choices: the model and runner catalogs, the saved
// default model suggested when scheduling, and the runner a new conversation
// starts on. Each fresh status read from the shell's setup owner reloads
// the catalogs. Automatic chat selection belongs to the server's Preset.
export function createChoices({ call, signal, get, patch, list, errorMessage }) {
  let status = null;

  async function load() {
    try {
      const [models, runners] = await Promise.all([call("/models?workload=text_generation"), call("/runners")]);
      if (signal.aborted) return;
      patch({ models: models.models, runners: runners.runners, choicesError: null });
      chooseRunner();
    } catch (error) {
      if (signal.aborted || error.name === "AbortError") return;
      patch({ choicesError: error, models: get().models ?? [], runners: get().runners ?? [] });
      errorMessage(error);
    }
  }

  function chooseRunner() {
    const chosen = runnerChoice(get().runners || [], { current: get().runner,
      defaultRunner: status?.defaults?.runner_executor_public_id, edited: get().runnerEdited });
    if (chosen && chosen.public_id !== get().runner) patch({ runner: chosen.public_id });
  }

  function observe({ document, status: next }) {
    // Choice values initialize once per draft. Plugin availability stays live
    // without copying later global choices over the person's own values.
    const modes = next?.defaults?.conversation_modes;
    if (!get().id && modes) patch({ modes: get().modes
      ? { ...get().modes, available: modes.available, code_mode_available: modes.code_mode_available } : modes });
    const defaultModel = document?.settings?.default_model || "";
    if (defaultModel !== get().defaultModel) patch({ defaultModel });
    if (!next || next === status) return;
    status = next;
    if (status.connected) { load(); list.refresh(); }
    chooseRunner();
  }

  return {
    observe,
    // A deliberate refresh reads the catalogs again once rho is connected.
    refresh() { if (status?.connected) { load(); list.refresh(); } },
  };
}
