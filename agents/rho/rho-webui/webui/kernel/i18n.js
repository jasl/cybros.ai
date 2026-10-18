import english from "../locales/en.js";

export const locale = "en";

// A plugin owns its metadata fallback; UI copy and branding belong to the
// catalog. Interpolation produces text only, never HTML or executable markup.
// `messages` are consulted first, then `fallback`; `{rho}` and `{nexus}` read
// the brand from `messages`, then `brand`.
export function createTranslator(messages = english, fallback = english, brand = english) {
  return (key, values = {}, missing) => {
    const template = messages[key] ?? fallback[key];
    if (template === undefined) {
      if (missing !== undefined) return missing;
      throw new Error(`Missing translation: ${key}`);
    }
    const replacements = { rho: messages["brand.rho"] ?? brand["brand.rho"],
      nexus: messages["brand.nexus"] ?? brand["brand.nexus"], ...values };
    return template.replace(/\{([a-zA-Z][a-zA-Z0-9_]*)\}/g, (_, name) => {
      if (!Object.hasOwn(replacements, name)) throw new Error(`Missing interpolation: ${key}.${name}`);
      return String(replacements[name]);
    });
  };
}

export const t = createTranslator();

// A module's own catalogs: the current locale, then its English. Shell keys
// never resolve through it; only the brand names are shared.
export function translator(catalogs) {
  const base = catalogs?.en;
  if (!base || typeof base !== "object") throw new Error("A module catalog needs an `en` entry");
  return createTranslator(catalogs[locale] ?? base, base, english);
}

export const statusText = (value) => t(`status.${value}`, {}, value || "");
export const pluginText = (plugin, field) => t(`plugins.${plugin.id}.${field}`, {}, plugin[field] || (field === "name" ? plugin.id : ""));
