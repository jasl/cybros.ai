// THE BUILDER LIBRARY — the whole world a compose script gets.
//
// A compose script is a PURE FUNCTION. It places steps on `g` in the
// order it writes them and returns nothing of its own; the kernel lowers
// what it placed and runs it. A later script stage can instead return a JSON
// value computed from its selected completed results. The script awaits nothing and calls no
// agent, which is the property that keeps the kernel the only driver.
//
// It runs in an isolate with NO host bindings: no fs, no network, no
// console, and — deliberately — no clock, no locale and no randomness.
// That is not prudishness: the same script must place the same steps,
// or resume and replay are lies.
//
// Every placement records the SOURCE LINE it was made from, so a kernel
// refusal that arrives as `steps[1].parallel[0].prompt` can be handed
// back to the model as the line of ITS OWN script that produced it.
//
// How a script is compiled and read against this library — `g`, the
// run's window, the entry points the evaluator calls — is run.js, loaded
// after this file into the same isolate.
(function () {
  "use strict";

  // The isolate ships a console; a pure builder has nothing to say.
  try { delete this.console; } catch (_e) { this.console = undefined; }

  // The clock, the locale and the collector's timing are removed rather
  // than discouraged: a global that answers differently on another host
  // or another day would fold into a step and break replay.
  ["Date", "Intl", "WeakRef", "FinalizationRegistry"].forEach(function (name) {
    try { delete this[name]; } catch (_e) { this[name] = undefined; }
    Object.defineProperty(this, name, {
      configurable: false,
      get: function () {
        throw new Error(
          name + " is unavailable: a compose script must build the same " +
          "graph every time it runs, or resume and replay would disagree. " +
          "Pass any timestamp you need through params."
        );
      },
    });
  }, this);
  Math.random = function () {
    throw new Error(
      "Math.random() is unavailable: a compose script must build the same " +
      "graph every time it runs. Pass a seed or the chosen values through " +
      "params."
    );
  };

  // The line the script is executing, recovered from a thrown stack so
  // no bookkeeping is asked of the author. Script code runs through
  // `new Function`, so V8 labels its frames `<anonymous>:LINE:COL` —
  // that label is what distinguishes the author's frames from this
  // library's, and the innermost one is the author's own call site.
  const SCRIPT_FRAME = /<anonymous>:(\d+):\d+/;

  function rawLine() {
    const stack = new Error().stack;
    if (typeof stack !== "string") return null;
    const frames = stack.split("\n").slice(1);
    for (const frame of frames) {
      const match = frame.match(SCRIPT_FRAME);
      if (match) return Number(match[1]);
    }
    return null;
  }

  // `new Function` prepends its own prologue and we prepend a strict
  // pragma, so a reported line is offset from the author's. MEASURED,
  // not assumed: a hard-coded constant would be silently wrong the day
  // V8 changes its wrapper.
  const LINE_OFFSET = (function () {
    const probe = new Function("report", '"use strict";\nreport();');
    let reported = null;
    probe(function () { reported = rawLine(); });
    return reported === null ? 0 : reported - 1;
  })();

  function callerLine() {
    const raw = rawLine();
    if (raw === null) return null;
    const line = raw - LINE_OFFSET;
    return line > 0 ? line : null;
  }

  function must(condition, message) {
    if (!condition) throw new Error(message);
  }

  // A step verb takes ONE object. A second argument would be read by
  // nothing — `g.tool({...}, { key: "k" })` would place a step under a
  // minted key and say so nowhere — and a dropped option is the silent
  // failure this library exists to refuse.
  function oneObject(verb, count) {
    must(count <= 1, "g." + verb + " takes one object: g." + verb +
      "({ ..., key: \"…\" }), not g." + verb + "({ ... }, { ... }).");
  }

  // The closed option set per verb. Everything else is REFUSED at the
  // line with a sentence that names the repair — never dropped, which is
  // how `g.ask({prompt})` once vanished at two layers. No step carries a
  // WHEN word: `wait` is on the compose CALL; the fan's join word is
  // `until`.
  const OPTIONS = {
    tool: ["name", "input", "key", "timeout_ms", "after"],
    model: ["prompt", "model", "tools", "instructions", "key", "after", "results"],
    ask: ["prompt", "options", "multi", "key", "timeout_ms", "after"],
    wait: ["task", "agent_loop", "key", "timeout_ms", "after"],
    script: ["script", "params", "key", "after", "results"],
    parallel: ["until"],
  };

  const EDGE_SENTENCE = ": is not an option. A step reads only what you hand it: " +
    "results: [a, b] on a g.model or g.script hands it those results; after: [a] " +
    "on any leaf waits without a result; no input_from or join.";

  // Every per-step spelling of "later" — the deleted `run_in_background`
  // included — is answered with the CALL's word and the fan.
  const LATER_SENTENCE = ": is not an option. The whole compose call runs in " +
    "the background unless you call it with wait: true; steps run in the " +
    "order you write them, and work nothing should wait on goes in its own " +
    "call or beside the rest in one g.parallel([...]).";

  // The fan's old join word: it collided with the call's boolean `wait`,
  // so on a fan it is answered with the fan's word and the call's home;
  // on a step it is one more per-step spelling of "later".
  const FAN_WAIT_SENTENCE = "wait: is not an option on g.parallel; the fan's " +
    "word is until: — \"all\" (the default), \"any\", or a number of successes — " +
    "and wait: true belongs on the compose call, outside the script.";

  // The words the old grammar spelled, each answered with its replacement.
  function deletedWord(verb, key) {
    switch (key) {
      case "input_from": case "depends_on": case "reading":
        return key + EDGE_SENTENCE;
      case "mode": case "quorum_k":
        return key + ": is not an option; the barrier word is until: on " +
          "g.parallel — \"all\" (the default), \"any\", or a number.";
      case "wait":
        return verb === "parallel" ? FAN_WAIT_SENTENCE : key + LATER_SENTENCE;
      case "lifetime": case "wake":
        return key + " is not a compose option on a step; set " + key + " on " +
          "the whole compose call, outside the script. All steps inherit that selection.";
      case "loser_policy": case "losers":
        return key + ": is not an option: a race from a script cancels its " +
          "losers; there is no loser option.";
      case "run_in_background": case "detached": case "detach": case "background":
      case "detachable": case "outlives_turn":
        return key + LATER_SENTENCE;
      case "serial":
        return "serial: is not an option: steps run in the order you write " +
          "them, one after another.";
      case "question":
        return "question: is not an option; the field is prompt.";
      case "on_failure":
        return "on_failure is not a compose option: a step that fails " +
          "reaches you as an error envelope.";
      case "retry": case "visibility": case "configuration": case "compaction":
      case "fan_on_failure": case "reasoning_effort":
        return key + " is not a compose option; the step inherits it from this round.";
      default:
        return null;
    }
  }

  // `results:` names what a model or a script reads; a tool reads nothing,
  // and waiting on a step is `after:` beside input.
  const TOOL_READS_SENTENCE = "a tool reads nothing. To wait for a step, write " +
    "after: [step] beside input; to use a step's result, give it to a g.model " +
    "or g.script with results: [step].";

  function unknownOption(verb, key) {
    const shown = JSON.stringify(key);
    switch (verb) {
      case "tool":
        if (key === "results") return "g.tool: results: is not an option; " + TOOL_READS_SENTENCE;
        return "g.tool: unknown option " + shown + ". Tool arguments go under " +
          "input: g.tool({ name: \"bash\", input: { command: … } })";
      case "parallel":
        return "g.parallel: unknown option " + shown + ". The one option is until.";
      default:
        return "g." + verb + ": unknown option " + shown + ". The options are " +
          OPTIONS[verb].join(", ") + ".";
    }
  }

  function checkOptions(verb, opts) {
    must(opts !== null && typeof opts === "object" && !Array.isArray(opts),
      "g." + verb + " takes one object of options, e.g. g." + verb + "({ ... })");
    for (const key of Object.keys(opts)) {
      if (OPTIONS[verb].indexOf(key) !== -1) continue;
      throw new Error(deletedWord(verb, key) || unknownOption(verb, key));
    }
  }

  function optionalString(verb, opts, key) {
    const value = opts[key];
    if (value === undefined || value === null) return undefined;
    must(typeof value === "string", "g." + verb + ": " + key + " must be a string");
    return value;
  }

  function requiredString(verb, opts, key, example) {
    const value = opts[key];
    must(typeof value === "string" && value.length > 0,
      "g." + verb + " needs a " + key + ", e.g. { " + key + ": " + example + " }");
    return value;
  }

  function optionalTimeout(verb, opts) {
    const value = opts.timeout_ms;
    if (value === undefined || value === null) return undefined;
    must(Number.isInteger(value) && value > 0,
      "g." + verb + ": timeout_ms must be a positive whole number of milliseconds");
    return value;
  }

  // A HANDLE IS A LABEL, NOT A RESULT. No result exists while the script
  // runs, so every road from a handle to a string — and every property a
  // result would have: `r1.includes(...)`, `.match`, `.output` — throws
  // the one sentence that names the repair. A plain object answered those
  // with V8's own "r1.includes is not a function", which taught nothing.
  // The model reference in the door's shape — a "provider/model" name, or
  // {model: "provider/model", reasoning_effort?} — refused here as the
  // kernel refuses it (`invalid_model`), so a script the evaluator accepts
  // is one the door accepts. Which models exist is still the kernel's to
  // know: a well-formed name it does not have is refused there.
  const MODEL_SENTENCE = "g.model: model is a name like \"provider/model\", or omit it to " +
    "run as the model you are";

  function modelName(value) {
    if (typeof value !== "string") return false;
    const slash = value.indexOf("/");
    return slash > 0 && slash < value.length - 1;
  }

  function modelReference(value) {
    if (typeof value === "string") {
      must(modelName(value), MODEL_SENTENCE);
      return { model: value };
    }
    must(typeof value === "object" && !Array.isArray(value) && modelName(value.model) &&
      (value.reasoning_effort === undefined || typeof value.reasoning_effort === "string"), MODEL_SENTENCE);
    return value;
  }

  const handles = new Map();

  function unknownResult(key) {
    return "The result of " + key + " is not known while the script runs. A " +
      "call returns only a label for its step; never put it in a prompt or " +
      "an input — pass it in results: to a later g.model or g.script step.";
  }

  // The label's own fields are `key` and `kind`; this library reads a
  // handle through the `handles` map, never through a property, so
  // nothing else is whitelisted. Symbols and `then` answer undefined: a
  // promise check or Object.prototype.toString must not throw where the
  // author cannot read the reason. Symbol.toPrimitive and Symbol.iterator
  // are the thrower, so `"" + h`, `${h}`, a group's `.join` and `[...h]`
  // throw the sentence — and so do an `in` probe and every enumeration:
  // `{ ...h }` into an input would otherwise carry the label's two fields
  // silently, the very leak the sentence exists to refuse. `toJSON` is
  // not a field, so JSON.stringify throws it too.
  function makeHandle(key, kind) {
    const target = Object.freeze({ key: key, kind: kind });
    const thrower = function () { throw new Error(unknownResult(key)); };
    const own = function (prop) { return Object.prototype.hasOwnProperty.call(target, prop); };
    return new Proxy(target, {
      get: function (_target, prop) {
        if (prop === Symbol.toPrimitive || prop === Symbol.iterator) return thrower;
        if (typeof prop === "symbol" || prop === "then") return undefined;
        if (own(prop)) return target[prop];
        throw new Error(unknownResult(key));
      },
      has: function (_target, prop) {
        if (own(prop)) return true;
        if (typeof prop === "symbol" || prop === "then") return false;
        throw new Error(unknownResult(key));
      },
      set: thrower,
      ownKeys: thrower,
    });
  }

  function handleKey(handle) {
    const entry = handles.get(handle);
    return entry.step[entry.verb].key;
  }

  // A label inside a tool's input is the same mistake as one in a prompt.
  function rejectHandles(value) {
    if (value === null || typeof value !== "object") return;
    if (handles.has(value)) throw new Error(unknownResult(handleKey(value)));
    for (const name of Object.keys(value)) rejectHandles(value[name]);
  }

  // Unless the label sits beneath an `after` or `results` key: that is the
  // step's own option written inside input, and the repair is where the
  // option goes. The key alone is no mistake — a tool may take an `after`
  // argument of its own — so only a label found beneath it is answered so.
  // `word` is the nearest such key above the value.
  function rejectInputHandles(value, tool, word) {
    if (value === null || typeof value !== "object") return;
    if (handles.has(value)) {
      throw new Error(word === undefined ? unknownResult(handleKey(value)) : misplacedReference(word, tool));
    }
    for (const name of Object.keys(value)) {
      rejectInputHandles(value[name], tool, name === "after" || name === "results" ? name : word);
    }
  }

  function misplacedReference(word, tool) {
    if (word === "after") {
      return "g.tool: after: goes beside input, not inside it: g.tool({ name: " +
        JSON.stringify(tool) + ", input: { ... }, after: [step] }).";
    }
    return "g.tool: results: does not go inside input; " + TOOL_READS_SENTENCE;
  }

  // The FRAMES: the script's sequence, and one more per function member
  // of a group. Every placement lands at the tip of the current frame.
  function Graph(toolExample) {
    this._frames = [[]];
    this._keys = Object.create(null);
    this._counters = Object.create(null);
    // A group's returned Array → its frame entry: inside a nested
    // sequence a group is a step like any other.
    this._groups = new Map();
    // Every chain a group returned — the copy it holds for a member written
    // as a nested sequence or a function, and the array the author wrote as
    // that sequence — so a reference that names one is answered as a chain,
    // never as a list the author nested.
    this._chains = new Set();
    this._toolExample = toolExample;
  }

  Graph.prototype._frame = function () {
    return this._frames[this._frames.length - 1];
  };

  // Keys are the model's if it names one, and generated if not — always
  // stable for a given script, because they count within the script.
  Graph.prototype._key = function (verb, given) {
    if (given !== undefined && given !== null) {
      must(typeof given === "string" && given.length > 0, "g." + verb + ": key must be a non-empty string");
      must(!this._keys[given], "duplicate task key: " + given);
      this._keys[given] = true;
      return given;
    }
    let key = verb + "-" + (this._counters[verb] = (this._counters[verb] || 0) + 1);
    while (this._keys[key]) key = verb + "-" + ++this._counters[verb];
    this._keys[key] = true;
    return key;
  };

  // The line tree mirrors the step tree: a placed step carries its line,
  // a group carries `{line, members}` — wherever it sits.
  function lineOf(entry) {
    return entry.group ? { line: entry.group.line, members: entry.group.members } : entry.line;
  }

  // How an entry is named in a refusal: a step by its key, a group by
  // its width — the model wrote no key for a group.
  function label(entry) {
    if (entry.group) return "the g.parallel([...]) of " + entry.step.parallel.length + " members";
    return JSON.stringify(entry.step[entry.verb].key);
  }

  Graph.prototype._place = function (verb, fields) {
    const step = {};
    step[verb] = fields;
    const handle = makeHandle(fields.key, verb);
    const entry = { handle: handle, step: step, verb: verb, line: callerLine() };
    handles.set(handle, entry);
    this._frame().push(entry);
    return handle;
  };

  // A REFERENCE NAMES ONE STEP: a leaf by its handle, or a race by the Array
  // its g.parallel returned — the race is one step, its barrier, and a
  // reader of it reads what it selected. The list itself being a race would
  // silently name every member instead, and an "all" group is no one step.
  Graph.prototype._references = function (verb, opts, fields) {
    for (const name of ["after", "results"]) {
      if (opts[name] === undefined || opts[name] === null) continue;
      must(Array.isArray(opts[name]), "g." + verb + ": " + name + " must be a list of earlier step handles");
      must(!this._race(opts[name]), "g." + verb + ": " + name + " takes a list; write " + name +
        ": [race] to name the race, not " + name + ": race.");
      const seen = new Set();
      fields[name] = opts[name].map(function (item) {
        const key = this._referenceKey(verb, name, item, opts[name]);
        must(!seen.has(key), "g." + verb + ": " + name + " lists " + key + " twice");
        seen.add(key);
        return key;
      }, this);
    }
  };

  // A LEAF OF A FORMED RACE IS NO LONGER NAMED ALONE: a script's race stops the members it did not
  // select, and a later step naming one waits on it and spares it — the race silently reversed.
  // The repair names the race by its line and its own `until`.
  function raceMember(verb, name, entry) {
    const race = entry.raced;
    const where = race.line === null ? "a member of an earlier race" : "a member of the race on line " + race.line;
    return "g." + verb + ": " + name + " names " + JSON.stringify(entry.step[entry.verb].key) + ", " + where +
      "; a race stops the members it did not select, so name the race itself: const race = g.parallel([...], " +
      "{ until: " + JSON.stringify(race.until) + " }); then " + name + ": [race].";
  }

  // Every leaf a race holds, at any depth of its member list — nested sequences, groups and a
  // member function's steps — marked with the nearest race that formed around it.
  function markRaced(items, race) {
    for (const item of items) {
      const entry = handles.get(item);
      if (entry !== undefined) {
        if (entry.raced === undefined) entry.raced = race;
      } else if (Array.isArray(item)) {
        markRaced(item, race);
      }
    }
  }

  Graph.prototype._race = function (item) {
    const group = this._groups.get(item);
    return group !== undefined && group.step.key !== undefined;
  };

  // A CHAIN IS NOT A STEP: a reader of a group whose members are chains names each chain's last
  // step, and the sentence is chosen over the whole list the author wrote. When a chain ends on an
  // "all" group, that repair would be refused in turn, so the sentence names the group's members
  // instead; a chain ending on a race keeps the repair, which builds. A list that also holds single
  // steps gets no expression to copy, since none can separate a chain from a group or a race there,
  // so the sentence shows each chain's last step written in its place.
  Graph.prototype._chainReference = function (verb, name, list) {
    const chains = list.filter(function (item) { return this._chains.has(item); }, this);
    const head = "g." + verb + ": " + name + ": an entry is a chain [a, b], not a step; ";
    const grouped = chains.some(function (chain) {
      const last = this._groups.get(chain[chain.length - 1]);
      return last !== undefined && last.step.key === undefined;
    }, this);
    if (grouped) return head + "the chain ends on a group; name that group's members' last steps instead.";
    if (chains.length === list.length) {
      return head + "name each chain's last step: " + name + ": chains.map((c) => c[c.length - 1]).";
    }
    return head + "name each chain's last step in its place: " + name +
      ": [review, other] for g.parallel([[read, review], other]).";
  };

  Graph.prototype._referenceKey = function (verb, name, item, list) {
    const entry = handles.get(item);
    if (entry !== undefined) {
      if (entry.raced !== undefined) throw new Error(raceMember(verb, name, entry));
      return entry.step[entry.verb].key;
    }
    const group = this._groups.get(item);
    must(group === undefined || group.step.key !== undefined, "g." + verb + ": " + name +
      " names an \"all\" group, which is not one step; list its steps instead: " + name + ": [a, b].");
    if (this._chains.has(item)) throw new Error(this._chainReference(verb, name, list));
    // An array no g.parallel returned is a list the author nested in the
    // list — most often the handles a `.map` built, which already are the list.
    must(group !== undefined || !Array.isArray(item), "g." + verb + ": " + name + ": [runs] nests a list; write " +
      name + ": runs — the array itself is the list of handles.");
    must(group !== undefined, "g." + verb + ": " + name + " accepts leaf handles and races, not result values or string keys; " +
      "pass the handle a builder returned: " + name + ": [a].");
    return group.step.key;
  };

  Graph.prototype.tool = function (opts) {
    oneObject("tool", arguments.length);
    const o = opts === undefined ? {} : opts;
    checkOptions("tool", o);
    const name = requiredString("tool", o, "name", this._toolExample);
    const fields = { key: this._key("tool", o.key), name: name };
    if (o.input !== undefined && o.input !== null) {
      must(typeof o.input === "object" && !Array.isArray(o.input),
        "g.tool: input must be an object, e.g. input: { path: \"a\" }");
      rejectInputHandles(o.input, name, undefined);
      fields.input = o.input;
    }
    const timeout = optionalTimeout("tool", o);
    if (timeout !== undefined) fields.timeout_ms = timeout;
    this._references("tool", o, fields);
    return this._place("tool", fields);
  };

  // `model` is OPTIONAL: omitted, the step runs as the model composing
  // it. A script cannot look up which models exist, so requiring one
  // meant guessing — and a guessed model reference is refused.
  Graph.prototype.model = function (opts) {
    oneObject("model", arguments.length);
    const o = opts === undefined ? {} : opts;
    checkOptions("model", o);
    const fields = { key: this._key("model", o.key), prompt: requiredString("model", o, "prompt", "\"...\"") };
    if (o.model !== undefined && o.model !== null) {
      // A label is an object too; placed here it would cross to the kernel
      // as the model reference.
      rejectHandles(o.model);
      fields.model = modelReference(o.model);
    }
    if (o.tools !== undefined && o.tools !== null) {
      must(Array.isArray(o.tools) && o.tools.every(function (name) { return typeof name === "string"; }),
        "g.model: tools names the tools this step keeps, e.g. tools: [\"read\", \"grep\"]");
      fields.tools = o.tools;
    }
    const instructions = optionalString("model", o, "instructions");
    if (instructions !== undefined) fields.instructions = instructions;
    this._references("model", o, fields);
    return this._place("model", fields);
  };

  Graph.prototype.ask = function (opts) {
    oneObject("ask", arguments.length);
    const o = opts === undefined ? {} : opts;
    checkOptions("ask", o);
    const fields = { key: this._key("ask", o.key), prompt: requiredString("ask", o, "prompt", "\"...\"") };
    // THE CHOICES AS DATA: `options` one string each, `multi` a boolean —
    // refused at the line by sentence, never dropped.
    if (o.options !== undefined) {
      must(Array.isArray(o.options) && o.options.every(function (item) { return typeof item === "string"; }),
        "g.ask: options must be a list of strings, e.g. options: [\"Postgres\", \"MySQL\"]");
      fields.options = o.options.slice();
    }
    if (o.multi !== undefined) {
      must(o.multi === true || o.multi === false, "g.ask: multi must be true or false");
      fields.multi = o.multi;
    }
    const timeout = optionalTimeout("ask", o);
    if (timeout !== undefined) fields.timeout_ms = timeout;
    this._references("ask", o, fields);
    return this._place("ask", fields);
  };

  // The target is an existing task's receipt, not a handle in this script.
  // Evaluation only places an observation; its deadline belongs to the graph.
  Graph.prototype.wait = function (opts) {
    oneObject("wait", arguments.length);
    const o = opts === undefined ? {} : opts;
    checkOptions("wait", o);
    const fields = { key: this._key("wait", o.key), task: requiredString("wait", o, "task", "\"r1t0\"") };
    const agentLoop = optionalString("wait", o, "agent_loop");
    if (agentLoop !== undefined) fields.agent_loop = agentLoop;
    const timeout = optionalTimeout("wait", o);
    if (timeout !== undefined) fields.timeout_ms = timeout;
    this._references("wait", o, fields);
    return this._place("wait", fields);
  };

  Graph.prototype.script = function (opts) {
    oneObject("script", arguments.length);
    const o = opts === undefined ? {} : opts;
    checkOptions("script", o);
    const fields = { key: this._key("script", o.key), script: requiredString("script", o, "script", "\"return null\"") };
    if (o.params !== undefined && o.params !== null) {
      must(typeof o.params === "object" && !Array.isArray(o.params), "g.script: params must be an object");
      rejectHandles(o.params);
      fields.params = o.params;
    }
    this._references("script", o, fields);
    return this._place("script", fields);
  };

  const MEMBER_SENTENCE = "g.parallel: every member must be a step built for " +
    "this group, e.g. g.parallel([g.tool({...}), g.model({...})]). ";

  // The group takes the TRAILING placed steps of the current frame that
  // are exactly its members, in any order; a nested array is a sequence
  // inside it; a function member is called in a fresh frame.
  Graph.prototype.parallel = function (list, opts) {
    must(arguments.length <= 2 && Array.isArray(list),
      "g.parallel takes one array: g.parallel([a, b]), not g.parallel(a, b).");
    must(list.length > 0, "g.parallel: needs at least one step.");
    const o = opts === undefined ? {} : opts;
    checkOptions("parallel", o);
    const line = callerLine();

    const claimed = new Set();
    const members = [];
    const returned = [];
    for (const item of list) this._member(item, claimed, members, returned);

    // The regroup rule: every claimed entry sits in the frame's tail. A step
    // the group does not list between its members is most often a chain a
    // helper placed and returned only the last step of.
    const frame = this._frame();
    const tail = frame.slice(frame.length - claimed.size);
    for (const entry of claimed) {
      if (tail.indexOf(entry) !== -1) continue;
      const between = label(frame.slice(frame.indexOf(entry) + 1).find(function (e) { return !claimed.has(e); }));
      throw new Error(MEMBER_SENTENCE + label(entry) + " was already placed earlier in the script " +
        "and followed by another step, " + between + ", that this group does not list. List a " +
        "chain of steps as one member, g.parallel([[a, b], other]), or write " + between + " after the group.");
    }
    const fields = { parallel: members.map(function (m) { return m.step; }) };
    checkMemberOrder(fields.parallel);
    const ends = o.until;
    if (ends !== undefined && ends !== null) {
      must(ends === "all" || ends === "any" || (Number.isInteger(ends) && ends > 0 && ends <= list.length),
        "until: expected \"all\", \"any\", or a number no larger than the group (" +
        list.length + "), got " + JSON.stringify(ends) + ".");
      fields.until = ends;
    }
    // A race is one step a later `after:` or `results:` may name, so its key
    // is minted here as a leaf's is — never taken from the script — and
    // crosses to the kernel on the race and on every reference to it.
    if (ends !== undefined && ends !== null && ends !== "all") {
      fields.key = this._key("parallel");
      markRaced(returned, { line: line, until: ends });
    }
    // A caught refusal must leave the already placed members available.
    frame.length = frame.length - claimed.size;
    const group = { step: fields, line: line, members: members.map(function (m) { return m.line; }) };
    const entry = { handle: returned, step: fields, verb: "parallel", line: line, group: group };
    frame.push(entry);
    this._groups.set(returned, entry);
    return returned;
  };

  // One list member: a handle placed in this frame, a nested array of
  // them (a sequence — whose own members may be groups: `member := step |
  // sequence`, and a sequence holds steps, g.parallel included, at any
  // depth), or a function placing steps in a frame of its own.
  Graph.prototype._member = function (item, claimed, members, returned) {
    if (typeof item === "function") {
      const built = [];
      this._frames.push(built);
      try {
        item();
      } finally {
        this._frames.pop();
      }
      must(built.length > 0, "g.parallel: a member function must build at least one step.");
      members.push({ step: built.map(function (e) { return e.step; }), line: built.map(lineOf) });
      const chain = built.map(function (e) { return e.handle; });
      this._chains.add(chain);
      returned.push(chain);
      return;
    }
    if (Array.isArray(item)) {
      must(!this._groups.has(item), "g.parallel: a g.parallel([...]) cannot be a member of another; " +
        "write the inner steps as a nested array: g.parallel([[a, b], c]).");
      must(item.length > 0, "g.parallel: a nested sequence needs at least one step.");
      const entries = item.map(function (h) { return this._claim(h, claimed); }, this);
      members.push({ step: entries.map(function (e) { return e.step; }), line: entries.map(lineOf) });
      const chain = item.slice();
      this._chains.add(chain);
      this._chains.add(item);
      returned.push(chain);
      return;
    }
    const entry = this._claim(item, claimed);
    members.push({ step: entry.step, line: entry.line });
    returned.push(item);
  };

  // A step handle or a group's Array, placed in this frame and not yet
  // claimed; the group case is what lets `[g.parallel([l, ty]), qs]`
  // stand as a sequence — the two-source fan-in's natural spelling.
  Graph.prototype._claim = function (item, claimed) {
    const entry = handles.get(item) || this._groups.get(item);
    must(entry !== undefined, MEMBER_SENTENCE + "Got " + describe(item) + ".");
    must(!claimed.has(entry), "g.parallel: " + label(entry) + " is listed twice.");
    if (this._frame().indexOf(entry) === -1) throw new Error(MEMBER_SENTENCE + this._elsewhere(entry));
    claimed.add(entry);
    return entry;
  };

  // Why a placed entry is not in this frame: this group runs inside a member
  // function and the entry was built outside it, or an earlier group took
  // it — the steps a member function builds are that group's members.
  Graph.prototype._elsewhere = function (entry) {
    const outside = this._frames.slice(0, -1).some(function (frame) { return frame.indexOf(entry) !== -1; });
    if (outside) {
      return label(entry) + " was built outside the member function this group is in; a group " +
        "inside a member function takes only the steps that function built. Build the step " +
        "inside the function, or group it outside.";
    }
    return label(entry) + " is already a member of an earlier g.parallel([...]); a step joins " +
      "one group, and the steps a member function builds are that group's members. Build a " +
      "new step for this group.";
  };

  // The kernel places a group's members in the order the list gives them,
  // walking nested sequences and groups in place, and a step may read or
  // wait on only a step already placed — a race once its members are. A
  // member naming one listed after it would be refused there, so it is
  // refused here, at the line.
  function checkMemberOrder(members) {
    const listed = new Set();
    eachLeaf(members, function (fields) { listed.add(fields.key); });
    const placed = new Set();
    eachLeaf(members, function (fields) {
      for (const name of ["results", "after"]) {
        const later = (fields[name] || []).find(function (key) { return listed.has(key) && !placed.has(key); });
        if (later === undefined) continue;
        const verb = name === "results" ? "reads" : "waits for";
        throw new Error("g.parallel: " + JSON.stringify(fields.key) + " " + verb + " " +
          JSON.stringify(later) + ", listed after it; list a step after the steps it " + verb + ".");
      }
      placed.add(fields.key);
    });
  }

  // Every placed step of a group's member list, in the kernel's order: a
  // race after its members, where the kernel places its barrier.
  function eachLeaf(members, visit) {
    for (const member of members) {
      for (const step of Array.isArray(member) ? member : [member]) {
        if (step.parallel) {
          eachLeaf(step.parallel, visit);
          if (step.key !== undefined) visit(step);
        } else {
          visit(step[Object.keys(step)[0]]);
        }
      }
    }
  }

  function describe(value) {
    try { return JSON.stringify(value); } catch (_e) { return String(typeof value); }
  }

  Graph.prototype._result = function () {
    const frame = this._frames[0];
    return {
      steps: frame.map(function (e) { return e.step; }),
      lines: frame.map(lineOf),
    };
  };

  // The run (run.js, loaded next into this isolate) reads a script against
  // these, and takes this hand-off off the global before any script runs.
  this.__nexusBuilder = { Graph: Graph, OPTIONS: OPTIONS, must: must };
}).call(this);
