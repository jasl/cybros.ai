// THE RUN — how the evaluator reads a compose script against the builder.
//
// Loaded after builder.js into the same isolate: it compiles the model's
// source, runs it inside the run's window with `g` as the builder's verbs,
// and hands back what the script placed or returned. The builder hands it
// the three things it reads — the graph, the option set and `must` — on a
// global this file takes off before any script runs.
(function () {
  "use strict";

  const builder = this.__nexusBuilder;
  delete this.__nexusBuilder;
  const Graph = builder.Graph;
  const OPTIONS = builder.OPTIONS;
  const must = builder.must;

  const JOIN_SENTENCE = "g.join is not a builder: the kernel places barriers. " +
    "Put the steps in g.parallel([...]) — until: \"all\" is the default, " +
    "\"any\" races them, a number is a quorum — and list what the next step needs in its results: [a, b].";

  // THE RUN'S WINDOW. A script places its steps while a reading runs it,
  // and the reading hands back what was placed when it returns. The rest of
  // an async function after its first `await`, or a `.then` callback, runs
  // after that — a step it placed would reach no graph — so `g` outside the
  // window places nothing: it notes the late call, which the evaluator reads
  // to refuse the script whole, and throws to stop the continuation.
  let running = false;
  let late = false;

  function during(read) {
    return function () {
      running = true;
      try {
        return read.apply(null, arguments);
      } finally {
        running = false;
      }
    };
  }

  function tooLate(prop) {
    late = true;
    throw new Error("g." + String(prop) + " was used after the script returned");
  }

  this.__nexusDeferred = function () { return late; };

  // `g` teaches the available graph verbs. A verb is checked when it is
  // CALLED, so one captured in time (`const tool = g.tool`) and called from
  // a continuation places nothing either.
  function facade(graph) {
    return new Proxy(graph, {
      get: function (target, prop) {
        if (typeof prop === "symbol") return undefined;
        if (!running) return tooLate(prop);
        if (Object.prototype.hasOwnProperty.call(OPTIONS, prop)) {
          const verb = target[prop];
          return function () {
            return running ? verb.apply(target, arguments) : tooLate(prop);
          };
        }
        if (prop === "join") throw new Error(JOIN_SENTENCE);
        throw new Error("g." + prop + " is not a compose verb. Build steps with " +
          "g.tool / g.model / g.ask / g.wait / g.script; run steps at once with g.parallel([step, ...]).");
      },
    });
  }

  // THE ONE COMPILE of a source, shared by the run and by __nexusCompiles:
  // a stage is a body of (g, params, results), a compose script a body of
  // (g, params).
  function compileBody(source, stage) {
    if (stage) return new Function("g", "params", "results", '"use strict";\n' + source);
    return new Function("g", "params", '"use strict";\n' + source);
  }

  // The script IS the function body — but a model reading "it receives
  // g and params" writes the function, and a bare `(g, params) => {...}`
  // is an expression `new Function` evaluates and throws away: nothing
  // placed, nothing said. So the body is tried first, as documented, and
  // a run that placed NOTHING gets one more reading — source-as-function,
  // with `g` and `params` in scope so a wrapper of any arity resolves them.
  function compileAsFunction(source) {
    return new Function("g", "params", '"use strict";\nreturn (' + source + "\n);");
  }

  function asFunction(source, g, params) {
    try {
      const value = compileAsFunction(source)(g, params);
      return typeof value === "function" ? value : null;
    } catch (_error) {
      return null;
    }
  }

  // Whether the run compiles the source: each reading the run would try is
  // built and never called. A SyntaxError a run raises is the author's
  // syntax only when no reading compiles; otherwise the running script
  // raised it (JSON.parse on a tool's output, a RegExp built from data).
  this.__nexusCompiles = function (source, stage) {
    return compiles(function () { compileBody(source, stage); }) ||
      (!stage && compiles(function () { compileAsFunction(source); }));
  };

  function compiles(compile) {
    try {
      compile();
      return true;
    } catch (_error) {
      return false;
    }
  }

  this.__nexusCompose = during(function (source, params, toolExample) {
    const frozen = Object.freeze(params || {});
    const example = JSON.stringify(toolExample || "<one of your tools>");
    let graph = new Graph(example);
    let body = null;
    let bodyError = null;
    try {
      body = compileBody(source, false);
    } catch (error) {
      bodyError = error;
    }
    if (body) body(facade(graph), frozen);
    if (!body || graph._frames[0].length === 0) {
      graph = new Graph(example);
      const g = facade(graph);
      const build = asFunction(source, g, frozen);
      if (build) build(g, frozen);
      else if (bodyError) throw bodyError;
    }
    return graph._result();
  });

  // JSON.stringify alone would silently erase undefined/functions and coerce
  // NaN to null. A stage must return the value it claimed, or fail atomically.
  function jsonValue(value, ancestors) {
    if (value === null || typeof value === "boolean") return value;
    if (typeof value === "string") {
      must(!value.includes("\u0000"), "A script result cannot contain a NUL character");
      return value;
    }
    if (typeof value === "number") {
      must(Number.isFinite(value), "A script result must contain finite JSON numbers");
      return value;
    }
    must(typeof value === "object", "A script must return a JSON value or place tasks and return undefined");
    must(!ancestors.has(value), "A script result cannot contain a cycle");
    const prototype = Object.getPrototypeOf(value);
    must(Array.isArray(value) || prototype === Object.prototype || prototype === null,
      "A script result must be JSON; promises and other object types are unsupported");
    must(Object.getOwnPropertySymbols(value).length === 0, "A script result cannot contain symbol keys");
    ancestors.add(value);
    let result;
    if (Array.isArray(value)) {
      result = Array.from(value, function (item) { return jsonValue(item, ancestors); });
    } else {
      result = Object.create(null);
      for (const key of Object.keys(value)) {
        must(!key.includes("\u0000"), "A script result cannot contain a NUL key");
        result[key] = jsonValue(value[key], ancestors);
      }
    }
    ancestors.delete(value);
    return result;
  }

  // What the step after this one would wait on, as the kernel places it: a
  // leaf is its own exit, a race its barrier, and a group of "all" the exits
  // of its members (a nested sequence's is its last step's).
  function exits(step) {
    if (!step.parallel) return ["leaf"];
    if (step.until !== undefined && step.until !== "all") return ["barrier"];
    return step.parallel.reduce(function (all, member) {
      return all.concat(exits(Array.isArray(member) ? member[member.length - 1] : member));
    }, []);
  }

  // A stage's outside reader follows its expansion's final step, so the
  // kernel accepts an expansion only when that is one leaf; a group of
  // "all" with one member ends on that member, and a race always ends on
  // its barrier.
  const STAGE_END_SENTENCE = "A g.script stage must end with ONE step such as g.model or " +
    "g.script, not a g.parallel([...]); add a step after the group whose results: name what it reads.";

  this.__nexusScript = during(function (source, params, results, toolExample) {
    const graph = new Graph(JSON.stringify(toolExample || "<one of your tools>"));
    const body = compileBody(source, true);
    const value = body(facade(graph), Object.freeze(params || {}), Object.freeze(results));
    const built = graph._result();
    if (built.steps.length > 0) {
      must(value === undefined, "A script cannot both return a value and place tasks");
      const ends = exits(built.steps[built.steps.length - 1]);
      must(ends.length === 1 && ends[0] === "leaf", STAGE_END_SENTENCE);
      return { outcome: "steps", steps: built.steps, lines: built.lines };
    }
    return { outcome: "value", value: jsonValue(value, new Set()) };
  });
}).call(this);
