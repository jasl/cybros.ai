import { el, icon } from "./dom.js";
import { t, locale } from "./i18n.js";
import { markdown } from "./markdown.js";

const ARTIFACT = /(?:^|[\s"'(])((?:\/|\.\.?\/)?[\w./@+-]*\.(?:png|jpe?g|gif|webp|avif|svg|log|txt|json|markdown|md))(?=$|[\s"'),.])/ig;
const PREVIEW_TYPES = new Map([
  ["md", "markdown"], ["markdown", "markdown"],
  ["png", "image/png"], ["jpg", "image/jpeg"], ["jpeg", "image/jpeg"], ["gif", "image/gif"],
  ["webp", "image/webp"], ["avif", "image/avif"], ["svg", "image/svg+xml"], ["ico", "image/x-icon"],
]);
const previewType = (artifact) => PREVIEW_TYPES.get((artifact.filename || artifact.path || "").match(/\.([^./]+)$/)?.[1].toLowerCase());

// Explicit paths can be read where the file is. Bare filenames need an
// attachment or published upload owned by the turn, not just a text mention.
export function artifactsIn(text) {
  const found = new Set();
  for (const match of String(text || "").matchAll(ARTIFACT)) if (match[1].includes("/")) found.add(match[1]);
  return [...found].map((path) => ({ path, filename: path.split("/").pop() }));
}

export const artifactKey = (turn, artifact) => JSON.stringify([
  turn.public_id, turn.active_variant?.public_id, artifact.public_id, artifact.path, artifact.filename,
]);

// A status refresh can arrive while remote bytes are loading. Keep that
// request's result node and buttons alive only for the same turn and variant.
export function preserveArtifacts(previous, next) {
  const figures = new Map();
  for (const figure of previous.querySelectorAll("[data-artifact-key]")) {
    const key = figure.dataset.artifactKey;
    if (!figures.has(key)) figures.set(key, []);
    figures.get(key).push(figure);
  }
  for (const figure of next.querySelectorAll("[data-artifact-key]")) {
    const existing = figures.get(figure.dataset.artifactKey)?.shift();
    if (existing) figure.replaceWith(existing);
  }
}

// Reads bytes through the authenticated boundary and shows them as a Blob
// URL that is revoked with the opener, never a token-bearing resource URL.
export function createArtifactOpener({ artifactBytes, host, signal }) {
  const urls = new Set();
  async function open(artifact, target, trigger, download = false) {
    trigger.disabled = true;
    try {
      const preview = !download && previewType(artifact);
      const blob = await artifactBytes(artifact, host(), signal, download);
      const text = preview === "markdown" ? await blob.text() : null;
      if (signal.aborted || !target.isConnected) return;
      if (target.dataset.objectUrl) { URL.revokeObjectURL(target.dataset.objectUrl); urls.delete(target.dataset.objectUrl); }
      const image = preview && preview !== "markdown";
      // Upload bytes can have a generic MIME type; the supported extension
      // selects the image decoder without changing the downloaded bytes.
      const url = URL.createObjectURL(image ? blob.slice(0, blob.size, preview) : blob); urls.add(url); target.dataset.objectUrl = url;
      const name = artifact.filename || artifact.path?.split("/").pop() || t("artifacts.artifact");
      const link = el("a", { class: "link", href: url, download: name, text: t("artifacts.save", { name }) });
      const contents = preview === "markdown" ? el("div", { class: "markdown" }, markdown(text)) :
        image ? el("img", { src: url, alt: name }) : el("p", { class: "text-tertiary", text: t("artifacts.size", { name, size: blob.size.toLocaleString(locale) }) });
      target.replaceChildren(contents, link);
      if (download) link.click();
    } catch (error) {
      if (!signal.aborted && target.isConnected) target.replaceChildren(el("p", { class: "text-bad", text: error.message }));
      throw error;
    } finally { trigger.disabled = false; }
  }
  return {
    open,
    figure(artifact, key = null) {
      const name = artifact.filename || artifact.path || t("artifacts.attachment");
      const result = el("div", { class: "artifact__result" });
      // The visible verb is short; the accessible name says which file.
      const action = (label, accessible, glyph, download) => el("button", { type: "button", class: "btn btn--secondary btn--sm", "aria-label": accessible,
        onclick: (event) => open(artifact, result, event.currentTarget, download).catch(() => {}) }, icon(glyph), el("span", { class: "btn__label", text: label }));
      return el("figure", { class: "artifact", "data-artifact-key": key },
        el("div", { class: "artifact__actions row" }, el("span", { class: "artifact__name mono truncate", text: name }),
          previewType(artifact) && action(t("artifacts.preview"), t("artifacts.preview_named", { name }), "image", false),
          action(t("artifacts.download"), t("artifacts.download_named", { name }), "download", true)), result);
    },
    dispose() { for (const url of urls) URL.revokeObjectURL(url); urls.clear(); },
  };
}
