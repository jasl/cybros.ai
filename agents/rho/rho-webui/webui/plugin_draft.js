const owns = (object, key) => Object.hasOwn(object, key);
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const under = (path, parent) => parent.length <= path.length && parent.every((key, index) => key === path[index]);

export function atPath(value, path) {
  for (const key of path) {
    if (!object(value) || !owns(value, key)) return undefined;
    value = value[key];
  }
  return value;
}

export function schemaAt(schema, path) {
  for (const key of path) schema = schema.properties?.[key] || schema.additionalProperties || {};
  return schema;
}

export function hasSecrets(schema) {
  return schema.writeOnly === true || Object.values(schema.properties || {}).some(hasSecrets)
    || (object(schema.additionalProperties) && hasSecrets(schema.additionalProperties))
    || (object(schema.items) && hasSecrets(schema.items));
}

function apply(document, operation) {
  let parent = document;
  for (const key of operation.path.slice(0, -1)) {
    if (!owns(parent, key) || !object(parent[key])) {
      if (operation.op === "unset") return;
      Object.defineProperty(parent, key, { value: {}, configurable: true, enumerable: true, writable: true });
    }
    parent = parent[key];
  }
  const key = operation.path.at(-1);
  if (operation.op === "unset") delete parent[key];
  else Object.defineProperty(parent, key, { value: structuredClone(operation.value), configurable: true, enumerable: true, writable: true });
}

function visible(value, schema) {
  if (schema.writeOnly) return undefined;
  if (Array.isArray(value)) return hasSecrets(schema.items || {}) ? undefined : value;
  if (!object(value)) return value;
  return Object.fromEntries(Object.entries(value).flatMap(([key, child]) => {
    const result = visible(child, schemaAt(schema, [key]));
    return result === undefined ? [] : [[key, result]];
  }));
}

// Diff visible overrides by named field. Redacted leaves never mean deletion;
// removing their containing named entry is an intentional whole-entry reset.
export function configurationEdits(before, after, schema, path = []) {
  if (schema.writeOnly) {
    if (!equal(before, after)) throw new Error("Use the separate secret controls to replace or clear credentials.");
    return [];
  }
  if (schema.type === "array" && hasSecrets(schema) && !equal(before, after)) {
    throw new Error("This list contains secrets and needs dedicated configuration controls.");
  }
  if (object(before) && object(after)) {
    return [...new Set([...Object.keys(before), ...Object.keys(after)])].flatMap((key) => {
      const child = schemaAt(schema, [key]);
      if (child.writeOnly) {
        if (owns(after, key)) throw new Error("Use the separate secret controls to replace or clear credentials.");
        return [];
      }
      if (!owns(after, key)) return [{ op: "unset", path: [...path, key] }];
      return configurationEdits(owns(before, key) ? before[key] : object(after[key]) ? {} : undefined,
        after[key], child, [...path, key]);
    });
  }
  if (equal(before, after)) return [];
  if (hasSecrets(schema)) {
    if (object(after)) return configurationEdits({}, after, schema, path);
    throw new Error("Reset this field explicitly or use the separate secret controls.");
  }
  return [{ op: "set", path, value: after }];
}

// The only browser-owned state is unsaved edits. The daemon owns canonical
// overrides, validation and application; a refresh cannot acknowledge a save.
export function pluginDraft(initial) {
  let view = initial;
  let edits = [];
  function stage(operation) {
    edits = edits.filter((previous) => !under(previous.path, operation.path));
    edits.push(operation);
  }
  function configuration() {
    const value = structuredClone(view.configuration.overrides);
    for (const edit of edits) apply(value, edit);
    return value;
  }
  return {
    view: () => view,
    update: (next) => { view = next; },
    dirty: () => edits.length > 0,
    operations: () => edits.slice(),
    overrides: () => visible(configuration(), view.configuration.schema),
    field: (path) => {
      const value = visible(configuration(), view.configuration.schema);
      const explicit = atPath(value, path);
      const touched = edits.some((edit) => under(path, edit.path) || under(edit.path, path));
      const fallback = touched ? schemaAt(view.configuration.schema, path).default : atPath(view.configuration.value, path);
      return { value: explicit === undefined ? fallback : explicit, overridden: explicit !== undefined };
    },
    set: (path, value) => stage({ op: "set", path, value }),
    unset: (path) => stage({ op: "unset", path }),
    keep: (path) => { edits = edits.filter((edit) => !equal(edit.path, path)); },
    editJSON: (value) => {
      const operations = configurationEdits(visible(configuration(), view.configuration.schema), value, view.configuration.schema);
      for (const operation of operations) stage(operation);
    },
    discard: () => { edits = []; },
    clearSecrets: () => { edits = edits.filter((edit) => !schemaAt(view.configuration.schema, edit.path).writeOnly); },
    acknowledge: (submitted, next) => {
      if (next) view = next;
      // Object identity keeps newer edits even when they have the same value.
      edits = edits.filter((edit) => !submitted.includes(edit));
    },
  };
}

export function pluginSaveMessage(answer) {
  if (answer.code === "settings_durability_uncertain") return "Published, but durability could not be confirmed. Do not retry this write; refresh status before making further changes.";
  if (!answer.saved) return "Changes were not saved. Your draft is kept for correction.";
  if (answer.restart_required) return "Saved. Restart rho to apply this change; the running plugin is unchanged.";
  if (!answer.applied) return "Saved, but not applied. The running plugin is unchanged; check the reported issues.";
  return "Saved and applied.";
}
