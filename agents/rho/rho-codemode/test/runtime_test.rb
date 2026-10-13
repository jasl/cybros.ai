require_relative "test_helper"

class RuntimeTest < Minitest::Test
  def setup
    @runtime = Rho::Codemode::Runtime.new
  end

  def test_one_vm_preserves_local_state_across_external_waits_longer_than_its_computation_budget
    runtime = Rho::Codemode::Runtime.new(timeout_ms: 50)
    created = 0
    factory = MiniRacer::Context.method(:new)
    input = program("let count = 0; await tools.a({}); count++; await tools.b({count}); return ++count;")
    requests = []
    MiniRacer::Context.define_singleton_method(:new) { |**options| created += 1; factory.call(**options) }
    result = runtime.call(program: input) do |state|
      if state.status == "request"
        requests.concat(state.requests)
        state.requests.map { |operation| accepted(operation) }
      else
        sleep 0.08
        [observed(state.pending.fetch(0), outcome("done"))]
      end
    end

    assert_equal "finished", result.status
    assert_equal 2, result.result.fetch("structured_content")
    assert_equal 1, created
    assert_equal %w[op_0 op_1], requests.map { |request| request.fetch("key") }
    assert_equal({ "count" => 1 }, requests.last.dig("request", "input"))
  ensure
    MiniRacer::Context.singleton_class.remove_method(:new)
    MiniRacer::Context.define_singleton_method(:new, factory)
  end

  def test_parallel_observations_arrive_in_order_and_callback_work_precedes_later_observations
    program = program(<<~JS)
      const a = tools.a({});
      const b = tools.b({}).then(async result => {
        text("b observed");
        const c = await tools.c({from: result.structured_content});
        return c;
      });
      return await Promise.all([a, b]);
    JS
    initial = evaluate(@runtime, program:)
    assert_equal "request", initial.status
    assert_equal %w[a b], initial.requests.map { |op| op.dig("request", "name") }
    trace = initial.requests.map { |op| accepted(op) }
    assert_equal "observe", evaluate(@runtime, program:, trace:).status
    trace << observed("op_1", outcome("B"))
    after_b = evaluate(@runtime, program:, trace:)
    assert_equal "request", after_b.status
    assert_equal "c", after_b.requests.first.dig("request", "name")
    assert_equal({ "from" => "B" }, after_b.requests.first.dig("request", "input"))
    trace << accepted(after_b.requests.first)
    trace << observed("op_0", outcome("A"))
    trace << observed("op_2", outcome("C"))
    result = evaluate(@runtime, program:, trace:)
    assert_equal "finished", result.status
    assert_equal [outcome("A"), outcome("C")], result.result.fetch("structured_content")
    assert_equal [{ "type" => "text", "text" => "b observed" }], result.result.fetch("content")
    assert_equal result, evaluate(@runtime, program:, trace:), "independent invocations produce the same selected result for the same outcomes"
  end

  def test_operation_count_has_no_cumulative_work_ceiling
    program = program("await Promise.all(Array.from({length: 1100}, (_, index) => tools.a({index}))); return true;")
    first = evaluate(@runtime, program:)
    assert_equal "request", first.status
    assert_equal 1100, first.requests.length
    assert_equal "op_1099", first.requests.last.fetch("key")
    assert_equal 1100, first.pending.length
  end

  def test_task_is_error_is_a_value_but_recorded_refusal_rejects
    program = program("return await Promise.allSettled([tools.a({}), tools.b({})]);")
    first = evaluate(@runtime, program:)
    trace = [accepted(first.requests[0]), refused(first.requests[1], "not_allowed"),
             observation_refused("op_1", "not_allowed"), observed("op_0", outcome(false, is_error: true))]
    result = evaluate(@runtime, program:, trace:)
    assert_equal "failed", result.status, "native Error is not silently flattened into JSON"

    program = program(<<~JS)
      const results = await Promise.allSettled([tools.a({}), tools.b({})]);
      return results.map(item => item.status === "fulfilled" ? item.value : item.reason.refusal);
    JS
    result = evaluate(@runtime, program:, trace:)
    assert_equal "finished", result.status
    assert_equal [outcome(false, is_error: true), { "code" => "not_allowed", "message" => "Refused" }], result.result.fetch("structured_content")
  end

  def test_refusal_catch_can_issue_a_new_operation
    program = program("try { await tools.a({}); } catch (error) { return await tools.b({reason: error.refusal.code}); }")
    first = evaluate(@runtime, program:)
    trace = [refused(first.requests.first, "not_allowed")]
    accepted_refusal = evaluate(@runtime, program:, trace:)
    assert_equal "observe", accepted_refusal.status, "acceptance facts do not deliver a Promise observation"
    assert_equal ["op_0"], accepted_refusal.pending
    trace << observation_refused("op_0", "not_allowed")
    second = evaluate(@runtime, program:, trace:)
    assert_equal "request", second.status
    assert_equal "op_1", second.requests.first.fetch("key")
    assert_equal({ "reason" => "not_allowed" }, second.requests.first.dig("request", "input"))
  end

  def test_refusal_catch_can_return_only_after_the_recorded_observation
    program = program("try { await tools.a({}); } catch (error) { return error.refusal.code; }")
    first = evaluate(@runtime, program:)
    trace = [refused(first.requests.first, "not_allowed")]
    pending = evaluate(@runtime, program:, trace:)
    assert_equal "observe", pending.status
    assert_equal ["op_0"], pending.pending

    trace << observation_refused("op_0", "not_allowed")
    result = evaluate(@runtime, program:, trace:)
    assert_equal "finished", result.status
    assert_equal "not_allowed", result.result.fetch("structured_content")
    assert_empty result.pending
  end

  def test_race_does_not_cancel_losers_and_unjoined_return_fails
    program = program("return await Promise.race([tools.a({}), tools.b({})]);")
    first = evaluate(@runtime, program:)
    trace = first.requests.map { |op| accepted(op) }
    trace << observed("op_1", outcome("B"))
    result = evaluate(@runtime, program:, trace:)
    assert_equal "failed", result.status
    assert_equal "unjoined_children", result.error.fetch("code")
    assert_equal ["op_0"], result.pending
    assert_empty result.requests
  end

  def test_race_can_keep_and_join_the_loser
    program = program(<<~JS)
      const a = tools.a({}), b = tools.b({});
      const winner = await Promise.race([a, b]);
      await Promise.all([a, b]);
      return winner;
    JS
    first = evaluate(@runtime, program:)
    trace = first.requests.map { |op| accepted(op) }
    trace << observed("op_1", outcome("B"))
    assert_equal "observe", evaluate(@runtime, program:, trace:).status
    trace << observed("op_0", outcome("A"))
    result = evaluate(@runtime, program:, trace:)
    assert_equal "finished", result.status
    assert_equal outcome("B"), result.result.fetch("structured_content")
  end

  def test_background_receipt_releases_ownership_without_resolving_original_promise
    program = program(<<~JS)
      const operation = tools.a({});
      operation.then(() => text("original settled"));
      await nexus.background({operation_key: operation.operation_key, lifetime: "conversation", wake: "auto"});
      return "transferred";
    JS
    first = evaluate(@runtime, program:)
    trace = first.requests.map { |op| accepted(op) }
    trace << observed("op_1", { "status" => "completed", "is_error" => false, "released_operations" => ["op_0"] })
    result = evaluate(@runtime, program:, trace:)
    assert_equal "finished", result.status
    assert_equal "transferred", result.result.fetch("structured_content")
    assert_empty result.result.fetch("content")
    assert_equal ["op_0"], result.pending
    assert_equal result, evaluate(@runtime, program:, trace:)
  end

  def test_background_failure_or_tool_result_cannot_release_other_operations
    program = program("const a = tools.a({}); await nexus.background({operation_key: a.operation_key}); return;")
    first = evaluate(@runtime, program:)
    trace = first.requests.map { |op| accepted(op) }
    trace << observed("op_1", { "status" => "completed", "is_error" => true, "released_operations" => ["op_0"] })
    assert_equal "unjoined_children", evaluate(@runtime, program:, trace:).error.fetch("code")

    program = program("tools.a({}); return await tools.b({});")
    first = evaluate(@runtime, program:)
    trace = first.requests.map { |op| accepted(op) }
    trace << observed("op_1", { "status" => "completed", "is_error" => false, "released_operations" => ["op_0"] })
    assert_equal "unjoined_children", evaluate(@runtime, program:, trace:).error.fetch("code")
  end

  def test_task_envelope_preserves_absent_null_false_and_uncertain_outcome
    envelope = { "status" => "uncertain", "is_error" => true, "content" => [], "structured_content" => nil, "error" => { "code" => "unknown_effect" } }
    program = program("return await tools.a({});")
    request = evaluate(@runtime, program:).requests.first
    result = evaluate(@runtime, program:, trace: [accepted(request), observed("op_0", envelope)])
    assert_equal envelope, result.result.fetch("structured_content")
    assert_nil evaluate(@runtime, program: program("return null;")).result.fetch("structured_content")
    ["return false;", "return 0;"].zip([false, 0]).each do |source, expected|
      result = evaluate(@runtime, program: program(source))
      assert result.result.key?("structured_content")
      assert_equal expected, result.result.fetch("structured_content")
    end
    refute evaluate(@runtime, program: program("return;")).result.key?("structured_content")
  end

  def test_generic_helpers_emit_neutral_operations_and_readonly_stable_keys
    %w[model ask steps replace cancel join background].each do |helper|
      program = program("const operation = nexus.#{helper}({prompt: params.prompt}); text(operation.operation_key); return await operation;", params: { "prompt" => "test" })
      request = evaluate(@runtime, program:).requests.first
      assert_equal "op_0", request.fetch("key")
      input = { "prompt" => "test" }
      input["tools"] = %w[a b c] if helper == "model"
      assert_equal({ "kind" => helper, "input" => input }, request.fetch("request"))
      result = evaluate(@runtime, program:, trace: [accepted(request), observed("op_0", outcome("done"))])
      assert_equal "finished", result.status
      assert_equal "op_0", result.result.fetch("content").first.fetch("text")
    end
    result = evaluate(@runtime, program: program('const operation = tools.a({}); operation.operation_key = "forged"; return await operation;'))
    assert_equal "language_error", result.error.fetch("code")
  end

  def test_final_output_is_selected_and_buffered
    program = program('const result = await tools.a({}); text("摘要"); value(false); resource({uri: "artifact:one", name: "document", mimeType: "application/pdf"});')
    request = evaluate(@runtime, program:).requests.first
    result = evaluate(@runtime, program:, trace: [accepted(request), observed("op_0", outcome("large intermediate"))])
    assert_equal "finished", result.status
    assert_equal false, result.result.fetch("structured_content")
    assert_equal ["text", "resource_link"], result.result.fetch("content").map { |item| item.fetch("type") }
    refute_includes JSON.generate(result.result), "large intermediate"
  end

  def test_mismatched_acceptance_or_invalid_observation_is_host_failure
    program = program("return await tools.a({x: 1});")
    request = evaluate(@runtime, program:).requests.first
    forged = accepted(request).merge("request" => { "kind" => "tool", "name" => "b", "input" => {} })
    result = evaluate(@runtime, program:, trace: [forged])
    assert_equal "host_event_error", result.error.fetch("code")
    result = evaluate(@runtime, program:, trace: [observed("op_0", outcome("fabricated"))])
    assert_equal "host_event_error", result.error.fetch("code")
  end

  def test_inserted_model_defaults_and_reordered_json_keys_match_the_pending_operation
    [
      'return await nexus.model({prompt:"hello",wake:"passive"});',
      'return await nexus.steps([{model:{prompt:"hello",wake:"passive"}}]);',
    ].each do |source|
      input = program(source)
      request = evaluate(@runtime, program: input).requests.first
      receipt = accepted(request)
      receipt["request"] = receipt.fetch("request").to_a.reverse.to_h
      result = evaluate(@runtime, program: input, trace: [receipt, observed("op_0", outcome("done"))])
      assert_equal "finished", result.status, result.error.inspect
      assert_equal outcome("done"), result.result.fetch("structured_content")
      assert_empty result.requests
    end
  end

  def test_language_errors_stalled_promises_and_abandoned_operations_fail
    { "await new Promise(() => {});" => "stalled_promise", "tools.a({}); return;" => "unjoined_children", "return await;" => "language_error", 'throw new Error("bad source");' => "language_error" }.each do |source, code|
      result = evaluate(@runtime, program: program(source))
      assert_equal "failed", result.status
      assert_equal code, result.error.fetch("code")
    end
  end

  def test_detached_callback_cannot_silently_request_work_after_return
    program = program("const a = tools.a({}); a.then(() => {}).then(() => {}).then(() => {}).then(() => tools.b({})); return await a;")
    request = evaluate(@runtime, program:).requests.first
    result = evaluate(@runtime, program:, trace: [accepted(request), observed("op_0", outcome("A"))])
    assert_equal "failed", result.status
    assert_equal "unjoined_children", result.error.fetch("code")
  end

  def test_reporting_a_thrown_value_does_not_invoke_its_callbacks
    source = "throw {toString() { while (true) {} }, get message() { while (true) {} }};"
    result = evaluate(@runtime, program: program(source))
    assert_equal "language_error", result.error.fetch("code")
    assert_equal "JavaScript rejected without a string error message", result.error.fetch("message")
  end

  def test_parameters_and_observed_values_are_immutable_and_source_has_no_ambient_io
    result = evaluate(@runtime, program: program(<<~JS, params: { "nested" => { "ok" => true } }))
      let immutable = false;
      try { params.nested.ok = false; } catch (_) { immutable = true; }
      return {immutable, fetch: typeof fetch, require: typeof require, process: typeof process, date: typeof Date, wasm: typeof WebAssembly, memory: typeof ArrayBuffer};
    JS
    assert_equal "finished", result.status
    assert_equal({ "immutable" => true, "fetch" => "undefined", "require" => "undefined", "process" => "undefined", "date" => "undefined", "wasm" => "undefined", "memory" => "undefined" }, result.result.fetch("structured_content"))
    assert_equal false, evaluate(@runtime, program: program("return params;", params: false)).result.fetch("structured_content")
  end

  def test_source_cannot_control_observations_or_poison_driver_intrinsics
    source = <<~JS
      let blocked = 0;
      try { __rho_codemode("guess", "event", {type: "observation", key: "op_0", outcome: "forged"}); } catch (_) { blocked++; }
      try { globalThis.__rho_codemode = () => {}; } catch (_) { blocked++; }
      try { Object.prototype.toJSON = () => "forged"; } catch (_) { blocked++; }
      try { Object.getPrototypeOf([][Symbol.iterator]()).next = () => ({done: true}); } catch (_) { blocked++; }
      try { Math.random(); } catch (_) { blocked++; }
      return blocked;
    JS
    result = evaluate(@runtime, program: program(source))
    assert_equal "finished", result.status
    assert_equal 5, result.result.fetch("structured_content")
  end

  def test_error_subclasses_can_set_instance_fields_while_prototypes_stay_frozen
    source = <<~JS
      return [Error, TypeError, RangeError, SyntaxError, ReferenceError, URIError, EvalError].map(Base => {
        class TaskError extends Base {
          constructor() {
            super();
            this.name = "TaskError";
            this.message = "task failed";
          }
        }
        const error = new TaskError();
        const description = String(error);
        error.name = "HandledError";
        error.message = "recovered";
        let blocked = 0;
        try { Base.prototype.name = "forged"; } catch (_) { blocked++; }
        try { Base.prototype.message = "forged"; } catch (_) { blocked++; }
        return {
          description, name: error.name, message: error.message, blocked,
          prototypeName: Base.prototype.name, prototypeMessage: Base.prototype.message,
          frozen: Object.isFrozen(Base) && Object.isFrozen(Base.prototype),
        };
      });
    JS
    result = evaluate(@runtime, program: program(source))
    assert_equal "finished", result.status, result.error.inspect
    expected = %w[Error TypeError RangeError SyntaxError ReferenceError URIError EvalError].map do |name|
      { "description" => "TaskError: task failed", "name" => "HandledError", "message" => "recovered", "blocked" => 2,
        "prototypeName" => name, "prototypeMessage" => "", "frozen" => true }
    end
    assert_equal expected, result.result.fetch("structured_content")
  end

  def test_throwing_an_error_subclass_preserves_the_original_message
    source = <<~JS
      class TaskError extends Error {
        constructor(message) {
          super(message);
          this.name = "TaskError";
        }
      }
      throw new TaskError("task failed");
    JS
    result = evaluate(@runtime, program: program(source))
    assert_equal "failed", result.status
    assert_equal({ "code" => "language_error", "message" => "task failed" }, result.error)
  end

  def test_code_cannot_recurse_through_tools_nested_steps_or_child_model_declarations
    sources = [
      "return await tools.code({code: 'return 1;'});",
      "return await nexus.steps([{tool:{name:'code',input:{code:'return 1;'}}}]);",
      "return await nexus.steps([{parallel:[[{tool:{name:'code',input:{}}}]]}]);",
      "return await nexus.background({steps:[{tool:{name:'code'}}],lifetime:'conversation',wake:'auto'});",
      "return await nexus.replace({operation_key:'op_0',tasks:['future'],steps:[{tool:{name:'code'}}]});",
      "return await nexus.model({prompt:'hello',tools:['code']});",
    ]
    sources.each do |source|
      input = program(source)
      result = evaluate(@runtime, program: input)
      assert_equal "language_error", result.error.fetch("code")
      assert_empty result.requests
    end

    input = program("return await nexus.steps([{model:{prompt:'hello'}}]);")
    input["model_defaults"] = { "tools" => ["b", Rho::Codemode::Code::NAME] }
    result = evaluate(@runtime, program: input)
    assert_equal ["b"], result.requests.first.dig("request", "input", 0, "model", "tools")
  end

  def test_missing_or_unsupported_frozen_binding_fails_before_any_request
    [[], [{ "name" => "code", "parameters" => {} }],
     [{ "name" => "code", "parameters" => { "$id" => "urn:cybros:rho:codemode:javascript:0" } }]].each do |binding|
      input = program("return await tools.a({});")
      input["tools"] = input.fetch("tools").reject { |tool| tool.fetch("name") == "code" } + binding
      result = evaluate(@runtime, program: input)
      assert_equal "failed", result.status
      assert_equal "unsupported_binding", result.error.fetch("code")
      assert_empty result.requests
    end
  end

  def test_nested_declaration_and_canonical_alias_use_the_same_binding_and_recursion_boundary
    input = program("return await tools.a({});")
    input["tools"][-1] = { "type" => "function", "canonical" => "code", "function" => {
      "name" => "execute_js", "parameters" => Rho::Codemode::Code::SCHEMA,
    } }
    assert_equal "request", evaluate(@runtime, program: input).status
    input["source"] = "return await tools.execute_js({code:'return 1;'});"
    result = evaluate(@runtime, program: input)
    assert_equal "language_error", result.error.fetch("code")
    assert_empty result.requests
  end

  def test_runner_qualified_bindings_preserve_callable_names_and_refuse_recursion
    input = program("return await tools.read__remote({path:'README.md'});")
    input["tools"] = [runner_declaration("read__remote", served: "read"),
      runner_declaration("code__remote", served: "code", parameters: Rho::Codemode::Code::SCHEMA),
      runner_declaration("code__other", served: "code", parameters: Rho::Codemode::Code::SCHEMA)]
    result = evaluate(@runtime, program: input)
    assert_equal "request", result.status
    assert_equal "read__remote", result.requests.fetch(0).dig("request", "name")
    assert_equal({ "path" => "README.md" }, result.requests.fetch(0).dig("request", "input"))

    ["return await tools.code__remote({code:'return 1;'});",
     "return await tools.code__other({code:'return 1;'});",
     "return await nexus.steps([{tool:{name:'code__remote',input:{code:'return 1;'}}}]);"].each do |source|
      result = evaluate(@runtime, program: input.merge("source" => source))
      assert_equal "language_error", result.error.fetch("code")
      assert_empty result.requests
    end
  end

  def test_runner_qualified_bindings_still_require_the_supported_schema
    [{}, { "$id" => "urn:cybros:rho:codemode:javascript:0" }].each do |parameters|
      input = program("return await tools.a({});")
      input["tools"] << runner_declaration("code__remote", served: "code", parameters: parameters)
      result = evaluate(@runtime, program: input)
      assert_equal "failed", result.status
      assert_equal "unsupported_binding", result.error.fetch("code")
      assert_empty result.requests
    end
  end

  def test_getters_and_non_json_results_are_not_silently_coerced
    ['return {get value() { return "side effect"; }};', "return NaN;", "return new Map();", "return [undefined];", "return {[Symbol('key')]: 1};"].each do |source|
      result = evaluate(@runtime, program: program(source))
      assert_equal "language_error", result.error.fetch("code")
    end
  end

  def test_synchronous_and_microtask_loops_are_bounded
    runtime = Rho::Codemode::Runtime.new(timeout_ms: 50)
    ["while (true) {}", "await Promise.resolve().then(() => { while (true) {} });", "while (true) { await Promise.resolve(); }"].each do |source|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = evaluate(runtime, program: program(source))
      assert_equal "execution_limit", result.error.fetch("code")
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
    end
    assert_equal "finished", evaluate(runtime, program: program("return 1;")).status
  end

  def test_cancellation_and_input_output_limits
    result = evaluate(@runtime, program: program("try { await tools.a({}); } catch (_) { return 1; }"), cancelled: -> { true })
    assert_equal "cancelled", result.error.fetch("code")
    result = evaluate(@runtime, program: program(" " * (Rho::Codemode::Runtime::MAX_PROGRAM_BYTES + 1)))
    assert_equal "input_limit", result.error.fetch("code")
    result = evaluate(@runtime, program: program('text("a".repeat(700000)); text("b".repeat(700000));'))
    assert_equal "output_limit", result.error.fetch("code")
  end

  def test_heap_pressure_stops_the_vm_without_preventing_the_next_invocation
    runtime = Rho::Codemode::Runtime.new(timeout_ms: 2_000, heap_bytes: 8 * 1024 * 1024)
    source = "const held = []; for (let i = 0; i < 1000000; i++) held.push({index: i}); return held.length;"
    result = evaluate(runtime, program: program(source))
    assert_equal "heap_limit", result.error.fetch("code")
    assert_equal "finished", evaluate(runtime, program: program("return 1;")).status
  end

  private

  # A fixture drives one live invocation. Breaking at an intermediate state
  # explicitly closes it; production hosts keep supplying events until completion.
  def evaluate(runtime, program:, trace: [], cancelled: -> { false })
    events = trace.dup
    runtime.call(program: program, cancelled: cancelled) do |state|
      break state if events.empty?

      [events.shift]
    end
  end

  def runner_declaration(name, served:, parameters: {})
    { "type" => "function", "function" => { "name" => name, "parameters" => parameters },
      "route" => { "kind" => "runner", "runner_executor_public_id" => SecureRandom.uuid_v7, "tool_name" => served } }
  end

  def program(source, params: {})
    tools = %w[a b c].map { |name| { "name" => name } }
    tools << { "name" => "code", "parameters" => Rho::Codemode::Code::SCHEMA }
    { "source" => source, "params" => params, "tools" => tools }
  end

  def accepted(request)
    request.merge("type" => "operation", "receipt" => { "task_keys" => ["child-#{request.fetch('key')}"], "result_task_keys" => ["child-#{request.fetch('key')}"], "steps" => [] })
  end

  def refused(request, code)
    request.merge("type" => "operation", "refusal" => { "code" => code, "message" => "Refused" })
  end

  def observed(key, outcome)
    { "type" => "observation", "key" => key, "outcome" => outcome }
  end

  def observation_refused(key, code)
    { "type" => "observation", "key" => key, "refusal" => { "code" => code, "message" => "Refused" } }
  end

  def outcome(value, is_error: false)
    { "status" => "succeeded", "is_error" => is_error, "content" => [], "structured_content" => value }
  end
end
