import { locale, t } from "./i18n.js";

// Display helpers shared by the conversation, the task tab and schedules.
export const isTerminal = (status) =>
  ["completed", "failed", "canceled", "cancelled", "timed_out", "skipped", "stopped"].includes(status);

// A failed task is actionable only until a resolution or its authored absorb
// policy accounts for it.
export const isUnresolvedFailure = (task) =>
  ["failed", "timed_out", "uncertain"].includes(task.status) && !task.failure_resolution && task.on_failure !== "absorb";

export const stamp = (value) => {
  const date = new Date(value);
  return value && !Number.isNaN(date.valueOf()) ? date.toLocaleString(locale) : "";
};

// Relative time for list rows, spoken in full: minutes and hours today,
// days this week, else a short date.
export function relativeStamp(value, now = Date.now()) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.valueOf())) return "";
  const seconds = Math.round((now - date.valueOf()) / 1000);
  const units = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (seconds < 60) return units.format(0, "minute");
  if (seconds < 3600) return units.format(-Math.round(seconds / 60), "minute");
  if (seconds < 86400) return units.format(-Math.round(seconds / 3600), "hour");
  if (seconds < 86400 * 7) return units.format(-Math.round(seconds / 86400), "day");
  return date.toLocaleDateString(locale, { month: "short", day: "numeric" });
}

// The same clock in the width a row affords (`now`, `3m`, `2h`, `3d`, then
// the short date); a row shows this and speaks `relativeStamp`.
export function compactStamp(value, now = Date.now()) {
  const date = new Date(value);
  if (!value || Number.isNaN(date.valueOf())) return "";
  const seconds = Math.round((now - date.valueOf()) / 1000);
  if (seconds < 60) return t("browser.stamp_now");
  if (seconds < 3600) return t("browser.stamp_minutes", { count: Math.round(seconds / 60) });
  if (seconds < 86400) return t("browser.stamp_hours", { count: Math.round(seconds / 3600) });
  if (seconds < 86400 * 7) return t("browser.stamp_days", { count: Math.round(seconds / 86400) });
  return date.toLocaleDateString(locale, { month: "short", day: "numeric" });
}

// A named thing's mark — a workspace, a bot — is its initial on a colour its
// id picks, so the rail tells them apart and each keeps its colour across
// sessions (`.mark--named` reads `--hue`).
export const initialOf = (name) => [...String(name ?? "").trim()][0]?.toUpperCase() || "";
export function hueOf(id) {
  let hash = 0;
  for (const unit of String(id ?? "")) hash = (hash * 31 + unit.codePointAt(0)) % 360;
  return hash;
}

export const modelRef = (model) => model
  ? (typeof model === "string" ? model : `${model.provider_id}/${model.model_ref}`) : "";
