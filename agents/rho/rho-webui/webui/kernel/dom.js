// All content enters through DOM text or the Markdown renderer. No model or
// tool output is interpreted as HTML.
export const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (name === "class") node.className = value;
    else if (name === "text") node.textContent = value;
    else if (name.startsWith("on")) node.addEventListener(name.slice(2), value);
    else node.setAttribute(name, value === true ? "" : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
};

// Icons are CSS masks keyed by name (`styles/icons.css`); the span is
// decorative and every icon-only control carries its own accessible name.
export const icon = (name) => el("span", { class: "icon", "data-icon": name, "aria-hidden": "true" });

// Order `nodes` inside `container` with the fewest moves: a node already in
// its place is never detached, so focus, selection and scroll inside it stay.
export function placeChildren(container, nodes) {
  nodes.forEach((node, index) => {
    const current = container.childNodes[index] || null;
    if (current !== node) container.insertBefore(node, current);
  });
}

// A link rendered from a server document or a module is navigated to only
// when it names a web address; anything else renders as plain text instead.
export function safeUrl(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:", "mailto:"].includes(url.protocol) ? url.href : null;
  } catch { return null; }
}

// A stable id for `aria-describedby`/`for` pairs created at runtime.
let sequence = 0;
export const uniqueId = (prefix = "rho") => `${prefix}-${++sequence}`;
