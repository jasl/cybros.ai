// A small DOM for `bun test`: enough of the tree, attributes, events, forms
// and selectors for the page's components to mount and be driven, with no
// layout. Install with `installDocument()`; the returned function restores
// the globals it replaced.

class Event {
  constructor(type, init = {}) {
    this.type = type;
    this.bubbles = init.bubbles ?? true;
    this.cancelable = init.cancelable ?? true;
    Object.assign(this, init);
    this.defaultPrevented = false;
    this.propagationStopped = false;
    this.target = null;
    this.currentTarget = null;
  }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() { this.propagationStopped = true; }
  stopImmediatePropagation() { this.propagationStopped = true; this.immediatelyStopped = true; }
}

class Node {
  constructor() { this.childNodes = []; this.parentNode = null; }
  get firstChild() { return this.childNodes[0] || null; }
  get lastChild() { return this.childNodes.at(-1) || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    return siblings[siblings.indexOf(this) + 1] || null;
  }
  get previousSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.childNodes;
    return siblings[siblings.indexOf(this) - 1] || null;
  }
  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node.nodeType === 9;
  }
  get ownerDocument() { return globalThis.document; }
  contains(other) {
    for (let node = other; node; node = node.parentNode) if (node === this) return true;
    return false;
  }
  appendChild(child) { this.insertBefore(child, null); return child; }
  insertBefore(child, reference) {
    if (child.nodeType === 11) { for (const node of [...child.childNodes]) this.insertBefore(node, reference); return child; }
    if (child.parentNode) child.parentNode.removeChild(child);
    const index = reference ? this.childNodes.indexOf(reference) : -1;
    if (index === -1) this.childNodes.push(child); else this.childNodes.splice(index, 0, child);
    child.parentNode = this;
    return child;
  }
  removeChild(child) {
    const index = this.childNodes.indexOf(child);
    if (index !== -1) { this.childNodes.splice(index, 1); child.parentNode = null; }
    return child;
  }
  append(...children) { for (const child of children) this.insertBefore(toNode(child), null); }
  prepend(...children) { const first = this.firstChild; for (const child of children) this.insertBefore(toNode(child), first); }
  replaceChildren(...children) { for (const child of [...this.childNodes]) this.removeChild(child); this.append(...children); }
  remove() { this.parentNode?.removeChild(this); }
  replaceWith(...nodes) {
    const parent = this.parentNode; if (!parent) return;
    const next = this.nextSibling; parent.removeChild(this);
    for (const node of nodes) parent.insertBefore(toNode(node), next);
  }
  before(...nodes) { for (const node of nodes) this.parentNode?.insertBefore(toNode(node), this); }
  after(...nodes) { const next = this.nextSibling; for (const node of nodes) this.parentNode?.insertBefore(toNode(node), next); }
  get textContent() { return this.childNodes.map((child) => child.textContent).join(""); }
  set textContent(value) { this.replaceChildren(); if (value !== "" && value !== null && value !== undefined) this.append(new Text(String(value))); }
}

class Text extends Node {
  constructor(data) { super(); this.nodeType = 3; this.data = String(data); }
  get textContent() { return this.data; }
  set textContent(value) { this.data = String(value); }
  get nodeValue() { return this.data; }
}

class DocumentFragment extends Node {
  constructor() { super(); this.nodeType = 11; }
}

const toNode = (value) => value?.nodeType ? value : new Text(value);
const BOOLEAN_ATTRIBUTES = new Set(["hidden", "disabled", "checked", "required", "open", "selected", "readonly", "inert", "multiple", "autofocus"]);

class Element extends Node {
  constructor(tagName) {
    super();
    this.nodeType = 1;
    this.tagName = tagName.toUpperCase();
    this.localName = tagName.toLowerCase();
    this.attributes = new Map();
    this.listeners = new Map();
    this.style = styleOf();
    this.classList = classListOf(this);
    this.dataset = datasetOf(this);
    this.scrollTop = 0; this.scrollHeight = 0; this.clientHeight = 0; this.offsetHeight = 0; this.offsetWidth = 0;
    if (["input", "textarea", "select", "button", "option"].includes(this.localName)) this.ownValue = "";
    if (this.localName === "input") this.checked = false;
  }
  get type() { return this.getAttribute("type") || (this.localName === "button" ? "submit" : this.localName === "input" ? "text" : ""); }
  set type(value) { this.setAttribute("type", value); }
  get min() { return this.getAttribute("min") || ""; }
  set min(value) { this.setAttribute("min", value); }
  get max() { return this.getAttribute("max") || ""; }
  set max(value) { this.setAttribute("max", value); }
  get step() { return this.getAttribute("step") || ""; }
  set step(value) { this.setAttribute("step", value); }
  // A control inside a disabled fieldset is disabled too, as in the browser.
  get inertControl() { return this.disabled || !!this.closest("fieldset[disabled]"); }
  get children() { return this.childNodes.filter((node) => node.nodeType === 1); }
  get firstElementChild() { return this.children[0] || null; }
  get lastElementChild() { return this.children.at(-1) || null; }
  get childElementCount() { return this.children.length; }
  get parentElement() { return this.parentNode?.nodeType === 1 ? this.parentNode : null; }
  get nextElementSibling() { let node = this.nextSibling; while (node && node.nodeType !== 1) node = node.nextSibling; return node; }
  get previousElementSibling() { let node = this.previousSibling; while (node && node.nodeType !== 1) node = node.previousSibling; return node; }
  get id() { return this.getAttribute("id") || ""; }
  set id(value) { this.setAttribute("id", value); }
  get className() { return this.getAttribute("class") || ""; }
  set className(value) { this.setAttribute("class", value); }
  get hidden() { return this.hasAttribute("hidden"); }
  set hidden(value) { this.toggleAttribute("hidden", !!value); }
  get disabled() { return this.hasAttribute("disabled"); }
  set disabled(value) { this.toggleAttribute("disabled", !!value); }
  get required() { return this.hasAttribute("required"); }
  set required(value) { this.toggleAttribute("required", !!value); }
  get open() { return this.hasAttribute("open"); }
  set open(value) { const was = this.open; this.toggleAttribute("open", !!value); if (was !== !!value && this.localName === "details") this.dispatchEvent(new Event("toggle", { bubbles: false })); }
  get inert() { return this.hasAttribute("inert"); }
  set inert(value) { this.toggleAttribute("inert", !!value); }
  get title() { return this.getAttribute("title") || ""; }
  set title(value) { this.setAttribute("title", value); }
  get href() { return this.getAttribute("href") || ""; }
  set href(value) { this.setAttribute("href", value); }
  get name() { return this.getAttribute("name") || ""; }
  set name(value) { this.setAttribute("name", value); }
  get placeholder() { return this.getAttribute("placeholder") || ""; }
  set placeholder(value) { this.setAttribute("placeholder", value); }
  get options() { return this.querySelectorAll("option"); }
  get selectedOptions() { return this.options.filter((option) => option.selected); }
  get selectedIndex() { return this.options.findIndex((option) => option.selected); }
  get value() {
    if (this.localName === "select") {
      const chosen = this.options.find((option) => option.selected) || this.options[0];
      return chosen ? chosen.value : "";
    }
    if (this.localName === "option") return this.hasAttribute("value") ? this.getAttribute("value") : this.textContent;
    // Like the browser's dirty-value flag: the `value` attribute is the
    // default until a script or person sets the property.
    if (this.valueDirty) return this.ownValue;
    return this.localName === "input" && this.hasAttribute("value") ? this.getAttribute("value") : this.ownValue ?? "";
  }
  set value(next) {
    if (this.localName === "select") {
      for (const option of this.options) option.selected = option.value === String(next);
      return;
    }
    if (this.localName === "option") { this.setAttribute("value", next); return; }
    this.valueDirty = true;
    this.ownValue = String(next);
  }
  get selected() { return this.hasAttribute("selected"); }
  set selected(value) { this.toggleAttribute("selected", !!value); }
  get innerText() { return this.textContent; }
  set innerText(value) { this.textContent = value; }
  get outerHTML() { return `<${this.localName}${[...this.attributes].map(([k, v]) => ` ${k}="${v}"`).join("")}>${this.childNodes.map((c) => c.nodeType === 1 ? c.outerHTML : c.textContent).join("")}</${this.localName}>`; }
  get innerHTML() { return this.childNodes.map((c) => c.nodeType === 1 ? c.outerHTML : c.textContent).join(""); }
  get form() { return this.closest("form"); }
  get labels() { return this.id ? globalThis.document.querySelectorAll(`label[for="${this.id}"]`) : []; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.has(name) ? this.attributes.get(name) : null; }
  hasAttribute(name) { return this.attributes.has(name); }
  removeAttribute(name) { this.attributes.delete(name); }
  toggleAttribute(name, force) {
    const present = force ?? !this.attributes.has(name);
    if (present) this.attributes.set(name, ""); else this.attributes.delete(name);
    return present;
  }
  addEventListener(type, listener, options) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    const entry = { listener, once: options?.once === true, signal: options?.signal };
    this.listeners.get(type).push(entry);
    entry.signal?.addEventListener("abort", () => this.removeEventListener(type, listener), { once: true });
  }
  removeEventListener(type, listener) {
    const list = this.listeners.get(type);
    if (list) this.listeners.set(type, list.filter((entry) => entry.listener !== listener));
  }
  dispatchEvent(event) {
    event.target = this;
    const path = [];
    for (let node = this; node; node = node.parentNode) path.push(node);
    path.push(globalThis.window);
    for (const node of event.bubbles ? path : [this]) {
      if (event.propagationStopped) break;
      event.currentTarget = node;
      for (const entry of [...(node.listeners?.get(event.type) || [])]) {
        if (entry.once) node.removeEventListener(event.type, entry.listener);
        if (typeof entry.listener === "function") entry.listener.call(node, event); else entry.listener.handleEvent(event);
        if (event.immediatelyStopped) break;
      }
    }
    return !event.defaultPrevented;
  }
  click() {
    if (this.inertControl) return;
    const proceed = this.dispatchEvent(new Event("click"));
    if (!proceed) return;
    if (this.localName === "button" && this.type === "submit") this.form?.requestSubmit(this);
    if (this.localName === "input" && ["checkbox", "radio"].includes(this.type)) {
      this.checked = this.type === "radio" ? true : !this.checked;
      this.dispatchEvent(new Event("input")); this.dispatchEvent(new Event("change"));
    }
    if (this.localName === "label") { const control = this.querySelector("input,button,select,textarea") || (this.getAttribute("for") && globalThis.document.getElementById(this.getAttribute("for"))); control?.click(); }
  }
  requestSubmit(submitter = null) {
    for (const field of this.querySelectorAll("[required]")) if (!field.disabled && !field.closest("[disabled]") && field.value === "") return;
    this.dispatchEvent(new Event("submit", { submitter }));
  }
  reset() { this.dispatchEvent(new Event("reset")); }
  focus() { globalThis.document.activeElement = this; this.dispatchEvent(new Event("focus", { bubbles: false })); this.dispatchEvent(new Event("focusin")); }
  blur() { if (globalThis.document.activeElement === this) globalThis.document.activeElement = globalThis.document.body; this.dispatchEvent(new Event("blur", { bubbles: false })); this.dispatchEvent(new Event("focusout")); }
  select() {}
  scrollIntoView() {}
  scrollTo() {}
  showModal() { this.open = true; }
  show() { this.open = true; }
  close() { if (!this.open) return; this.open = false; this.dispatchEvent(new Event("close", { bubbles: false })); }
  showPopover() { this.setAttribute("data-popover-open", ""); this.dispatchEvent(new Event("toggle", { bubbles: false, newState: "open" })); }
  hidePopover() { if (!this.hasAttribute("data-popover-open")) return; this.removeAttribute("data-popover-open"); this.dispatchEvent(new Event("toggle", { bubbles: false, newState: "closed" })); }
  togglePopover(force) { const open = force ?? !this.hasAttribute("data-popover-open"); if (open) this.showPopover(); else this.hidePopover(); return open; }
  getBoundingClientRect() { return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 }; }
  getAnimations() { return []; }
  animate() { return { finished: Promise.resolve(), cancel() {}, finish() {} }; }
  matches(selector) { return parseSelectorList(selector).some((complex) => matchesComplex(this, complex)); }
  closest(selector) { for (let node = this; node && node.nodeType === 1; node = node.parentNode) if (node.matches(selector)) return node; return null; }
  querySelectorAll(selector) {
    const scoped = selector.replace(/:scope\s*>\s*/g, ":scope>");
    const found = [];
    const walk = (node) => { for (const child of node.childNodes) { if (child.nodeType === 1) { found.push(child); walk(child); } } };
    walk(this);
    return found.filter((node) => parseSelectorList(scoped).some((complex) => matchesComplex(node, complex, this)));
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  getElementById(id) { return this.querySelector(`[id="${id}"]`); }
}

function styleOf() {
  const values = new Map();
  return new Proxy({ setProperty: (name, value) => values.set(name, String(value)), removeProperty: (name) => values.delete(name), getPropertyValue: (name) => values.get(name) || "" }, {
    get: (target, name) => name in target ? target[name] : (values.get(name) ?? ""),
    set: (_target, name, value) => { values.set(name, String(value)); return true; },
  });
}

function classListOf(element) {
  const read = () => (element.getAttribute("class") || "").split(/\s+/).filter(Boolean);
  const write = (names) => element.setAttribute("class", names.join(" "));
  return {
    add: (...names) => write([...new Set([...read(), ...names])]),
    remove: (...names) => write(read().filter((name) => !names.includes(name))),
    toggle: (name, force) => { const has = read().includes(name); const want = force ?? !has; if (want && !has) write([...read(), name]); if (!want && has) write(read().filter((n) => n !== name)); return want; },
    contains: (name) => read().includes(name),
    get length() { return read().length; },
  };
}

function datasetOf(element) {
  const attribute = (name) => `data-${name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;
  return new Proxy({}, {
    get: (_target, name) => element.hasAttribute(attribute(name)) ? element.getAttribute(attribute(name)) : undefined,
    set: (_target, name, value) => { element.setAttribute(attribute(name), value); return true; },
    deleteProperty: (_target, name) => { element.removeAttribute(attribute(name)); return true; },
    has: (_target, name) => element.hasAttribute(attribute(name)),
  });
}

// Selectors: tag, #id, .class, [attr], [attr="value"], :not(simple), a few
// state pseudo-classes, compounds, descendant and child combinators, lists.
function parseSelectorList(selector) {
  return selector.split(",").map((part) => part.trim()).filter(Boolean).map(parseComplex);
}
function parseComplex(text) {
  const tokens = text.replace(/\s*>\s*/g, " > ").trim().split(/\s+/);
  const steps = [];
  let combinator = " ";
  for (const token of tokens) {
    if (token === ">") { combinator = ">"; continue; }
    steps.push({ combinator, compound: parseCompound(token) });
    combinator = " ";
  }
  return steps;
}
function parseCompound(text) {
  const parts = { tag: null, scope: false, tests: [] };
  const pattern = /(:scope)|([a-zA-Z][\w-]*)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:([~|^$*]?=)"?([^"\]]*)"?)?\]|:not\(([^)]+)\)|:([a-z-]+)/gy;
  let match;
  while ((match = pattern.exec(text))) {
    const [, scope, tag, id, className, name, operator, value, not, state] = match;
    if (scope) parts.scope = true;
    else if (tag) parts.tag = tag.toLowerCase();
    else if (id) parts.tests.push((node) => node.id === id);
    else if (className) parts.tests.push((node) => node.classList.contains(className));
    else if (name) {
      parts.tests.push((node) => {
        if (!node.hasAttribute(name)) return false;
        const actual = node.getAttribute(name);
        if (!operator) return true;
        if (operator === "=") return actual === value;
        if (operator === "^=") return actual.startsWith(value);
        if (operator === "$=") return actual.endsWith(value);
        if (operator === "*=") return actual.includes(value);
        if (operator === "~=") return actual.split(/\s+/).includes(value);
        return false;
      });
    } else if (not) { const inner = parseCompound(not); parts.tests.push((node) => !matchesCompound(node, inner)); }
    else if (state) parts.tests.push(pseudo(state));
  }
  return parts;
}
function pseudo(name) {
  switch (name) {
    case "disabled": return (node) => node.disabled;
    case "enabled": return (node) => !node.disabled;
    case "checked": return (node) => !!node.checked || node.selected;
    case "first-child": return (node) => node.parentNode?.children[0] === node;
    case "last-child": return (node) => node.parentNode?.children.at(-1) === node;
    case "empty": return (node) => node.childNodes.length === 0;
    case "focus": return (node) => globalThis.document.activeElement === node;
    default: return () => false;
  }
}
function matchesCompound(node, compound, scope = null) {
  if (compound.scope) return node === scope;
  if (compound.tag && node.localName !== compound.tag) return false;
  return compound.tests.every((test) => test(node));
}
function matchesComplex(node, steps, scope = null) {
  let index = steps.length - 1;
  if (!matchesCompound(node, steps[index].compound, scope)) return false;
  let current = node;
  while (index > 0) {
    const { combinator } = steps[index];
    index -= 1;
    const want = steps[index].compound;
    if (combinator === ">") {
      current = current.parentNode;
      if (!current || current.nodeType !== 1 && !(want.scope && current === scope)) return false;
      if (!matchesCompound(current, want, scope)) return false;
    } else {
      let ancestor = current.parentNode;
      while (ancestor && !(ancestor.nodeType === 1 && matchesCompound(ancestor, want, scope)) && !(want.scope && ancestor === scope)) ancestor = ancestor.parentNode;
      if (!ancestor) return false;
      current = ancestor;
    }
  }
  return true;
}

class Document extends Node {
  constructor() {
    super();
    this.nodeType = 9;
    this.listeners = new Map();
    this.documentElement = this.createElement("html");
    this.head = this.createElement("head");
    this.body = this.createElement("body");
    this.documentElement.append(this.head, this.body);
    this.insertBefore(this.documentElement, null);
    this.activeElement = this.body;
    this.title = "";
    this.hidden = false;
    this.visibilityState = "visible";
  }
  createElement(tag) { return new Element(tag); }
  createElementNS(_ns, tag) { return new Element(tag); }
  createTextNode(text) { return new Text(text); }
  createDocumentFragment() { return new DocumentFragment(); }
  getElementById(id) { return this.documentElement.querySelector(`[id="${id}"]`); }
  querySelector(selector) { return this.documentElement.matches(selector) ? this.documentElement : this.documentElement.querySelector(selector); }
  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  addEventListener(...args) { Element.prototype.addEventListener.apply(this, args); }
  removeEventListener(...args) { Element.prototype.removeEventListener.apply(this, args); }
  dispatchEvent(event) { return Element.prototype.dispatchEvent.call(this, event); }
  hasFocus() { return true; }
}

class Storage {
  constructor() { this.map = new Map(); }
  getItem(key) { return this.map.has(key) ? this.map.get(key) : null; }
  setItem(key, value) { this.map.set(key, String(value)); }
  removeItem(key) { this.map.delete(key); }
  clear() { this.map.clear(); }
}

export function installDocument({ url = "http://localhost/", dark = false } = {}) {
  const names = ["document", "window", "Event", "CustomEvent", "KeyboardEvent", "PointerEvent", "MouseEvent", "InputEvent", "HTMLElement", "Element", "Node", "localStorage", "sessionStorage", "matchMedia", "requestAnimationFrame", "cancelAnimationFrame", "getComputedStyle", "location", "history", "navigator", "innerWidth", "innerHeight", "addEventListener", "removeEventListener", "dispatchEvent", "listeners"];
  const previous = Object.fromEntries(names.map((name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  const document = new Document();
  const window = globalThis;
  const define = (name, value) => Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
  define("document", document);
  define("window", window);
  define("listeners", new Map());
  define("Event", Event); define("CustomEvent", Event); define("KeyboardEvent", Event); define("PointerEvent", Event); define("MouseEvent", Event); define("InputEvent", Event);
  define("HTMLElement", Element); define("Element", Element); define("Node", Node);
  define("localStorage", new Storage()); define("sessionStorage", new Storage());
  define("matchMedia", (query) => ({ matches: dark && query.includes("dark"), media: query, addEventListener() {}, removeEventListener() {} }));
  define("requestAnimationFrame", (callback) => setTimeout(() => callback(performance.now()), 0));
  define("cancelAnimationFrame", (id) => clearTimeout(id));
  define("getComputedStyle", () => ({ getPropertyValue: () => "" }));
  define("location", new URL(url));
  define("history", { state: null, pushState(_state, _title, href) { globalThis.location = new URL(href, globalThis.location); }, replaceState(_state, _title, href) { globalThis.location = new URL(href, globalThis.location); } });
  define("navigator", { clipboard: { writeText: async () => {} }, language: "en" });
  define("innerWidth", 1440); define("innerHeight", 900);
  define("addEventListener", (...args) => Element.prototype.addEventListener.apply(window, args));
  define("removeEventListener", (...args) => Element.prototype.removeEventListener.apply(window, args));
  define("dispatchEvent", (event) => {
    event.target = window; event.currentTarget = window;
    for (const entry of [...(window.listeners.get(event.type) || [])]) entry.listener.call(window, event);
    return !event.defaultPrevented;
  });
  return () => {
    for (const [name, descriptor] of Object.entries(previous)) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name];
    }
  };
}

// Drive a control the way a person would.
export function type(field, value) {
  field.value = value;
  field.dispatchEvent(new Event("input"));
  field.dispatchEvent(new Event("change"));
}
export function key(target, key, init = {}) {
  const event = new Event("keydown", { key, ...init });
  target.dispatchEvent(event);
  return event;
}
export const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
