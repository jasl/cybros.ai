// Only the host controller can accept operations or deliver observations.
// Source has no host callbacks: its entire effect surface is the frozen bridge.
(() => {
  "use strict";
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const stringify = JSON.stringify;
  const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  const state = {
    status: "running", issued: [], pending: new Map(), accepted: new Set(), released: new Set(),
    nextKey: 0, content: [], result: undefined, error: null,
  };
  let capability;
  const allowedTools = new Set();
  let modelTools = [];

  // The binding accepts JSON values. In particular, it does not invoke toJSON
  // or getters while copying values into an operation or the final envelope.
  function copy(value, depth = 0, budget = { nodes: 0 }) {
    if (depth > 64 || ++budget.nodes > 65_536) throw new Error("JSON value exceeds the structural limit");
    if (value === null || typeof value === "boolean") return value;
    if (typeof value === "string") {
      if (value.length > 1_048_576) throw new Error("JSON string exceeds the size limit");
      return value;
    }
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value !== "object") throw new TypeError("Expected a finite JSON value");
    const array = Array.isArray(value);
    const prototype = Object.getPrototypeOf(value);
    if (!array && prototype !== null && prototype !== Object.prototype) {
      throw new TypeError("Expected a plain JSON object");
    }
    const result = array ? [] : Object.create(null);
    if (Object.getOwnPropertySymbols(value).length) throw new TypeError("JSON properties require string keys");
    const descriptors = Object.getOwnPropertyDescriptors(value);
    if (array) {
      if (value.length > 65_536) throw new Error("JSON array exceeds the size limit");
      for (let index = 0; index < value.length; index++) {
        const descriptor = descriptors[index];
        if (!descriptor || !own(descriptor, "value")) throw new TypeError("JSON arrays must contain values");
        result.push(copy(descriptor.value, depth + 1, budget));
      }
    } else {
      for (const key of Object.keys(descriptors).sort()) {
        const descriptor = descriptors[key];
        if (!descriptor.enumerable) continue;
        if (!own(descriptor, "value")) throw new TypeError("JSON properties must contain values");
        result[key] = copy(descriptor.value, depth + 1, budget);
      }
    }
    return result;
  }

  function freeze(value) {
    if (value !== null && typeof value === "object") {
      for (const child of Object.values(value)) freeze(child);
      Object.freeze(value);
    }
    return value;
  }

  function request(body) {
    if (state.status !== "running") {
      if (state.status === "finished") {
        state.status = "failed";
        state.error = { code: "unjoined_children", message: "A detached callback requested work after the program returned" };
      }
      throw new Error("The program has already returned");
    }
    const key = `op_${state.nextKey++}`;
    const operation = freeze({ key, request: prepare(copy(body)) });
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    Object.defineProperty(promise, "operation_key", { value: key, enumerable: true });
    state.pending.set(key, { resolve, reject, request: operation.request });
    state.issued.push(operation);
    return promise;
  }

  function model(input) {
    if (input === null || typeof input !== "object" || Array.isArray(input)) throw new TypeError("Model input must be an object");
    const names = own(input, "tools") ? input.tools : modelTools;
    if (!Array.isArray(names)) throw new TypeError("Model tools must be an array of declared names");
    for (const name of names) {
      if (!allowedTools.has(name)) throw new TypeError(`Tool is outside this program's callable catalog: ${name}`);
    }
    input.tools = [...names];
  }

  function steps(value) {
    if (!Array.isArray(value)) return;
    for (const step of value) {
      if (Array.isArray(step)) steps(step);
      else if (step !== null && typeof step === "object") {
        if (own(step, "tool") && !allowedTools.has(step.tool?.name)) {
          throw new TypeError(`Tool is outside this program's callable catalog: ${step.tool?.name}`);
        }
        if (own(step, "model")) model(step.model);
        if (own(step, "parallel")) steps(step.parallel);
      }
    }
  }

  function prepare(request) {
    if (request.kind === "model") model(request.input);
    else if (request.kind === "steps") steps(Array.isArray(request.input) ? request.input : request.input?.steps);
    else if (request.kind === "replace" || request.kind === "background") steps(request.input?.steps);
    return request;
  }

  function languageError(error) {
    state.status = "failed";
    let message = "JavaScript rejected without a string error message";
    // A thrown object can define arbitrary toString/getter behavior. Reporting
    // that failure must not execute another source callback or lose the error.
    try {
      if (typeof error === "string") message = error;
      else if (error !== null && typeof error === "object") {
        const descriptor = Object.getOwnPropertyDescriptor(error, "message");
        if (descriptor && typeof descriptor.value === "string") message = descriptor.value;
      }
    } catch (_) {
      // The fixed message remains truthful for a hostile Proxy trap.
    }
    state.error = { code: "language_error", message };
  }

  function start(program) {
    const tools = Object.create(null);
    for (const declaration of program.tools || []) {
      const name = declaration.name;
      if (typeof name !== "string" || !name || own(tools, name)) throw new Error("Invalid or duplicate tool name");
      allowedTools.add(name);
      tools[name] = input => request({ kind: "tool", name, input: input === undefined ? {} : input });
    }
    modelTools = (program.model_defaults?.tools || [...allowedTools]).filter(name => allowedTools.has(name));
    const nexus = Object.create(null);
    for (const kind of ["model", "ask", "steps", "replace", "cancel", "join", "background"]) {
      nexus[kind] = input => request({ kind, input: input === undefined ? {} : input });
    }
    const text = value => {
      if (typeof value !== "string") throw new TypeError("text() requires a string");
      state.content.push({ type: "text", text: copy(value) });
    };
    const value = output => { state.result = copy(output); };
    const resource = reference => {
      const output = copy(reference);
      if (typeof output.uri !== "string" || typeof output.name !== "string") {
        throw new TypeError("resource() requires uri and name");
      }
      state.content.push({ ...output, type: "resource_link" });
    };
    try {
      const run = new AsyncFunction("tools", "nexus", "params", "text", "value", "resource", `"use strict";\n${program.source}`);
      run(freeze(tools), freeze(nexus), freeze(copy(own(program, "params") ? program.params : {})), text, value, resource).then(
        result => {
          if (result !== undefined) state.result = copy(result);
          state.status = "finished";
        },
        languageError,
      ).catch(languageError);
    } catch (error) {
      languageError(error);
    }
  }

  function refuse(pending, refusal) {
    const value = freeze(copy(refusal));
    const error = new Error(value.message || "The operation was refused");
    Object.defineProperty(error, "refusal", { value, enumerable: true });
    pending.reject(error);
  }

  function event(record) {
    if (state.status === "failed") throw new Error("Host event follows program failure");
    if (record.type === "operation") {
      const issued = state.issued.shift();
      // Default insertion can change property order without changing the JSON
      // operation. Compare both in canonical key order, including nested steps.
      if (!issued || issued.key !== record.key || stringify(copy(issued.request)) !== stringify(copy(record.request))) {
        throw new Error("Accepted operation differs from the pending request");
      }
      if (own(record, "receipt") === own(record, "refusal")) throw new Error("Operation needs one receipt or refusal");
      state.accepted.add(record.key);
      // Acceptance captures a receipt or refusal, but only the separately
      // recorded observation delivers it to source and settles its Promise.
    } else if (record.type === "observation") {
      if (state.issued.length) throw new Error("Observation precedes acceptance of issued operations");
      const pending = state.pending.get(record.key);
      if (!state.accepted.has(record.key) || !pending) throw new Error("Observation has no unsettled accepted operation");
      if (own(record, "outcome") === own(record, "refusal")) throw new Error("Observation needs one outcome or refusal");
      state.pending.delete(record.key);
      if (own(record, "refusal")) refuse(pending, record.refusal);
      else {
        const outcome = freeze(copy(record.outcome));
        // This is an ownership receipt from the host, not a child result.
        // Releasing a task must not invent a settlement for its Promise.
        if (pending.request.kind === "background" && outcome.status === "completed" && !outcome.is_error) {
          for (const key of outcome.released_operations || []) {
            if (!state.accepted.has(key)) throw new Error("Background receipt names an unaccepted operation");
            state.released.add(key);
          }
        }
        pending.resolve(outcome);
      }
    } else {
      throw new Error("Unknown trace event type");
    }
  }

  function snapshot() {
    const pending = [...state.pending.keys()];
    if (state.status === "finished" && pending.some(key => !state.released.has(key))) {
      state.status = "failed";
      state.error = { code: "unjoined_children", message: "Return requires settling or explicitly disposing every child operation" };
    } else if (state.status === "running" && pending.length === 0) {
      state.status = "failed";
      state.error = { code: "stalled_promise", message: "The program is waiting without a possible external observation" };
    }
    let status = state.status;
    if (status === "running") status = state.issued.length ? "request" : "observe";
    const result = { content: state.content };
    if (state.result !== undefined) result.structured_content = state.result;
    return {
      status, requests: status === "request" ? state.issued : [], pending,
      result: status === "finished" ? result : null, error: state.error,
    };
  }

  // Keep host control data in a closure. Merely finding this global does not
  // let generated source forge an acceptance receipt or Promise observation.
  Object.defineProperty(globalThis, "__rho_codemode", {
    value: function (token, command, payload) {
      if (capability === undefined && command === "start") capability = token;
      if (token !== capability) throw new Error("Host control is unavailable to source");
      if (command === "start" && state.nextKey === 0 && state.status === "running") start(payload);
      else if (command === "event") event(payload);
      else if (command === "snapshot") return snapshot();
      else throw new Error("Invalid host control command");
      return null;
    },
  });

  const unavailable = () => { throw new Error("Ambient clock and randomness are unavailable; use fixed parameters or recorded operations"); };
  Math.random = unavailable;
  String.prototype.localeCompare = unavailable;
  String.prototype.toLocaleLowerCase = unavailable;
  String.prototype.toLocaleUpperCase = unavailable;
  Number.prototype.toLocaleString = unavailable;
  BigInt.prototype.toLocaleString = unavailable;
  Array.prototype.toLocaleString = unavailable;
  for (const name of ["Date", "Intl", "WeakRef", "FinalizationRegistry", "SharedArrayBuffer", "Atomics", "WebAssembly", "ArrayBuffer", "DataView", "Uint8Array", "Uint8ClampedArray", "Uint16Array", "Uint32Array", "Int8Array", "Int16Array", "Int32Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array", "gc", "console"]) {
    Object.defineProperty(globalThis, name, { value: undefined, writable: false, configurable: false });
  }
  const errors = [Error, TypeError, RangeError, SyntaxError, ReferenceError, URIError, EvalError];
  // Freezing inherited data properties would also reject ordinary subclass
  // assignments such as this.name. Keep those writes on the instance only.
  for (const ErrorType of errors) {
    const prototype = ErrorType.prototype;
    for (const key of ["name", "message"]) {
      const initial = prototype[key];
      Object.defineProperty(prototype, key, {
        get() { return initial; },
        set(value) {
          if (this === prototype) throw new TypeError("Cannot modify a frozen error prototype");
          Object.defineProperty(this, key, { value, writable: true, enumerable: true, configurable: true });
        },
      });
    }
  }
  for (const intrinsic of [Object, Function, Array, Promise, Map, Set, String, Number, Boolean, BigInt, Symbol, RegExp, ...errors]) {
    Object.freeze(intrinsic.prototype);
    Object.freeze(intrinsic);
    Object.defineProperty(globalThis, intrinsic.name, { value: intrinsic, writable: false, configurable: false });
  }
  // Iterators have prototypes of their own. Freezing Array.prototype alone
  // would still allow source to replace the iterator used by bridge copying.
  for (const instance of [[][Symbol.iterator](), ""[Symbol.iterator](), new Map()[Symbol.iterator](), new Set()[Symbol.iterator](), (function* () {})(), (async function* () {})()]) {
    let prototype = Object.getPrototypeOf(instance);
    while (prototype !== null && !Object.isFrozen(prototype)) {
      Object.freeze(prototype);
      prototype = Object.getPrototypeOf(prototype);
    }
  }
  Object.freeze(Math);
  Object.freeze(JSON);
  Object.defineProperty(globalThis, "Math", { value: Math, writable: false, configurable: false });
  Object.defineProperty(globalThis, "JSON", { value: JSON, writable: false, configurable: false });
})();
