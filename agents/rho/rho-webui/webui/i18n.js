import english from "./locales/en.js";

export const locale = "en";

// A plugin owns its metadata fallback; UI copy and branding belong to the
// catalog. Interpolation produces text only, never HTML or executable markup.
export function createTranslator(messages = english) {
  return (key, values = {}, fallback) => {
    const template = messages[key] ?? english[key];
    if (template === undefined) {
      if (fallback !== undefined) return fallback;
      throw new Error(`Missing translation: ${key}`);
    }
    const replacements = { rho: messages["brand.rho"] ?? english["brand.rho"],
      nexus: messages["brand.nexus"] ?? english["brand.nexus"], ...values };
    return template.replace(/\{([a-zA-Z][a-zA-Z0-9_]*)\}/g, (_, name) => {
      if (!Object.hasOwn(replacements, name)) throw new Error(`Missing interpolation: ${key}.${name}`);
      return String(replacements[name]);
    });
  };
}

export const t = createTranslator();

export const statusText = (value) => t(`status.${value}`, {}, value || "");
export const pluginText = (plugin, field) => t(`plugins.${plugin.id}.${field}`, {}, plugin[field] || (field === "name" ? plugin.id : ""));
