$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "mini_racer"
require "minitest/autorun"
require "socket"
require "support/manual_client"
require "support/manual_anthropic"
require "support/manual_openrouter"
require "support/manual_provider"
require "support/task_bench"
require_relative "recording_adapter"

# THE MANUAL LANES, before any money is spent: a model ref names its lane through the one provider
# table — `openrouter/…` through the broker, `deepseek/deepseek-flash` direct on the official API
# with its own key — and the wire and endpoint are the catalog's for that provider, so the floor a
# bench names is the one it measures. One builder makes every manual client; the paid gate refuses
# before a request is built. Nothing is sent: a client is constructed over a placeholder key.
class ManualClientHarnessTest < Minitest::Test
  Lanes = E2E::ProviderLanes
  Client = E2E::ManualClient
  KEYS = { "DEEPSEEK_API_KEY" => "direct-placeholder", "OPENROUTER_API_KEY" => "broker-placeholder",
           "ANTHROPIC_API_KEY" => "anthropic-placeholder", "OPENAI_API_KEY" => "openai-placeholder",
           "XAI_API_KEY" => "xai-placeholder" }.freeze
  LIVE = { "E2E_LIVE" => "1", "RAILS_ENV" => "development" }.freeze

  def test_the_direct_floor_ref_names_the_official_deepseek_lane_and_its_own_key
    route = Lanes.route("deepseek/deepseek-flash")
    assert_equal "deepseek/deepseek-flash", route.ref
    assert_equal "deepseek-flash", route.model, "the wire carries the provider's own id"
    assert_equal Lanes::Lane.new(provider_id: "deepseek", format: "deepseek_responses",
      base_url: "https://api.deepseek.com", key_name: "DEEPSEEK_API_KEY"), route.lane
  end

  def test_a_broker_ref_names_the_broker_lane
    route = Lanes.route("openrouter/z-ai/glm-5.3-flash")
    assert_equal "z-ai/glm-5.3-flash", route.model
    assert_equal Lanes::Lane.new(provider_id: "openrouter", format: "openrouter_chat",
      base_url: "https://openrouter.ai/api", key_name: "OPENROUTER_API_KEY"), route.lane
    assert_equal "moonshotai/kimi-k3", Lanes.route("openrouter/moonshotai/kimi-k3").model
  end

  # THE DIRECT xAI LANE: `xai/grok-4.7` on the official API, the catalog's `xai_responses` wire at
  # its own endpoint, read under its own key; the wire carries the vendor's id.
  def test_the_xai_ref_names_the_direct_xai_lane_and_its_own_key
    route = Lanes.route("xai/grok-4.7")
    assert_equal "grok-4.7", route.model
    assert_equal Lanes::Lane.new(provider_id: "xai", format: "xai_responses",
      base_url: "https://api.x.ai", key_name: "XAI_API_KEY"), route.lane
    assert_equal "XAI_API_KEY", Lanes.key_name_for("xai/grok-4.6")

    client = Client.for(route, env: KEYS.merge("XAI_API_KEY" => "xai-placeholder"))
    assert_equal ["https://api.x.ai", "xai-placeholder"], [client.config.base_url, client.config.api_key]
    assert_equal %w[xai xai_responses grok-4.7],
      client.execution_profile.then { |profile| [profile.provider_id, profile.adapter_profile, profile.model_pin] }
  end

  # A BARE BROKER ID NAMES NO LANE: `deepseek/deepseek-v4.1-flash` is the broker's id for the model,
  # and read as a ref its first segment would send it to the direct API under a name the catalog
  # does not list — refused by name, like every id the catalog does not name, before a call is paid.
  def test_an_id_the_catalog_does_not_name_is_refused_by_name
    %w[deepseek/deepseek-v4.1-flash z-ai/glm-5.3 nobody/some-model].each do |id|
      error = assert_raises(ArgumentError) { Lanes.route(id) }
      assert_includes error.message, id.inspect
    end
    oauth = assert_raises(ArgumentError) { Lanes.route("codex_subscription/gpt-6-luna") }
    assert_match(/no e2e key/, oauth.message, "a catalog provider whose key the harness never reads has no manual lane")
  end

  # THE PROVIDER FOLLOWS THE MODEL: the direct DeepSeek floor reads its own key, the broker's rows
  # the broker's, each provider under the catalog's own id; a provider off the map has no lane (a
  # live journey skips), and a set of models enables each provider it names once.
  def test_the_key_names_follow_the_provider_segment
    assert_equal "DEEPSEEK_API_KEY", Lanes.key_name_for("deepseek/deepseek-flash")
    assert_equal "deepseek", Lanes.provider_of("deepseek/deepseek-flash")
    assert_equal "OPENROUTER_API_KEY", Lanes.key_name_for("openrouter/z-ai/glm-5.3-flash")
    assert_equal "OPENAI_API_KEY", Lanes.key_name_for("openai_api/gpt-6-luna"), "the catalog's provider id"
    assert_equal "GEMINI_API_KEY", Lanes.key_name_for("gemini/gemini-3.8-flash"), "the catalog's provider id"
    assert_nil Lanes.key_name_for("nobody/some-model")
    assert_equal({ "openrouter" => "OPENROUTER_API_KEY", "deepseek" => "DEEPSEEK_API_KEY" },
      Lanes.provider_keys_for(%w[openrouter/z-ai/glm-5.3 openrouter/moonshotai/kimi-k3 deepseek/deepseek-flash]))
    assert_equal({ "nobody" => nil }, Lanes.provider_keys_for(%w[nobody/some-model]))
  end

  # THE ROUTED CLIENT: the lane's endpoint, wire and key, the ref's own model on the profile, and a
  # timeout above the longest authoring round observed (380 s) — a non-streaming call waits for the
  # whole answer.
  def test_a_routed_client_carries_the_lanes_endpoint_wire_key_and_the_timeout
    assert_operator Client::TIMEOUT_SECONDS, :>, 380
    direct = Client.for(Lanes.route("deepseek/deepseek-flash"), env: KEYS)
    assert_equal "https://api.deepseek.com", direct.config.base_url
    assert_equal "direct-placeholder", direct.config.api_key
    assert_in_delta Client::TIMEOUT_SECONDS, direct.config.timeout
    assert_equal %w[deepseek deepseek_responses deepseek-flash],
      direct.execution_profile.then { |profile| [profile.provider_id, profile.adapter_profile, profile.model_pin] }
    assert direct.execution_profile.capability_enabled?("tool_calls"), "a bench declares tools"

    broker = Client.for(Lanes.route("openrouter/z-ai/glm-5.3"), env: KEYS)
    assert_equal ["https://openrouter.ai/api", "broker-placeholder"], [broker.config.base_url, broker.config.api_key]
    assert_equal %w[openrouter openrouter_chat z-ai/glm-5.3],
      broker.execution_profile.then { |profile| [profile.provider_id, profile.adapter_profile, profile.model_pin] }
    assert_in_delta Client::TIMEOUT_SECONDS, broker.config.timeout
  end

  # THE THREE NAMED LANES ARE THE ONE BUILDER: the broker by its own model id, the direct Anthropic
  # lane with the capabilities its cache probe needs, the OpenAI smoke — each at its own timeout.
  def test_the_named_lanes_are_callers_of_the_one_builder
    broker = E2E::ManualOpenRouter.client("microsoft/phi-4", KEYS)
    assert_equal %w[openrouter openrouter_chat microsoft/phi-4],
      broker.execution_profile.then { |profile| [profile.provider_id, profile.adapter_profile, profile.model_pin] }
    assert_in_delta Client::TIMEOUT_SECONDS, broker.config.timeout

    anthropic = E2E::ManualAnthropic.client(KEYS)
    assert_equal ["https://api.anthropic.com", "anthropic_messages", E2E::ManualAnthropic::DEFAULT_MODEL],
      [anthropic.config.base_url, anthropic.execution_profile.adapter_profile, anthropic.execution_profile.model_pin]
    assert(%w[tool_calls prompt_caching reasoning].all? { |name| anthropic.execution_profile.capability_enabled?(name) })

    openai = E2E::ManualProvider.client(KEYS)
    assert_equal ["https://api.openai.com", "openai_api", "openai_responses", E2E::ManualProvider::DEFAULT_MODEL],
      [openai.config.base_url, openai.execution_profile.provider_id, openai.execution_profile.adapter_profile,
       openai.execution_profile.model_pin]
  end

  # ONE CALL'S FACTS READ ONE WAY ON BOTH WIRES: the Responses family says `incomplete` and puts
  # why in its detail, so a cut-off answer and a filtered one differ only there; the gem's reading
  # names the exhausted budget on the direct lane and on the broker's chat wire alike, and the
  # spend is one shape on both. Every bench records a call's finish through this one reader.
  def test_a_calls_facts_keep_the_typed_finish_and_read_an_exhausted_budget_on_both_wires
    direct = Lanes.route("deepseek/deepseek-flash")
    usage = { "input_tokens" => 5_000, "output_tokens" => 4_096 }
    cut = facts(direct, { "id" => "resp_1", "object" => "response", "status" => "incomplete", "output" => [],
                          "usage" => usage, "incomplete_details" => { "reason" => "max_output_tokens" } })
    assert_equal({ "finish" => "incomplete", "finish_detail" => "max_output_tokens",
                   "finish_quality" => "output_budget_exhausted", "usage" => usage }, cut)

    filtered = facts(direct, { "id" => "resp_1", "object" => "response", "status" => "incomplete", "output" => [],
                               "incomplete_details" => { "reason" => "content_filter" } })
    assert_equal({ "finish" => "incomplete", "finish_detail" => "content_filter", "finish_quality" => "refused" }, filtered,
      "a filter is not the cap: the gem reads it as the provider declining")

    broker = facts(Lanes.route("openrouter/z-ai/glm-5.3-flash"),
      { "id" => "gen-1", "object" => "chat.completion", "usage" => { "prompt_tokens" => 4_000, "completion_tokens" => 4_096, "cost" => 0.002 },
        "choices" => [{ "index" => 0, "finish_reason" => "length", "message" => { "role" => "assistant", "content" => "" } }] })
    assert_equal({ "finish" => "length", "finish_detail" => "length", "finish_quality" => "output_budget_exhausted",
                   "usage" => { "input_tokens" => 4_000, "output_tokens" => 4_096, "cost" => 0.002 } }, broker)
  end

  # THE KERNEL'S CACHE MARKERS ON A BENCH CALL: on the one wire that reads explicit breakpoints the
  # compiled request carries the placer's two — the system block's (tools and system cached as one
  # prefix) and the tail on the last message — and the lane admits them; every other wire is handed
  # its material unchanged, byte for byte. Unmarked, every Anthropic draw paid the full input rate on a
  # tool set a production round reads from cache.
  def test_an_anthropic_bench_call_carries_the_kernels_two_cache_markers
    route = Lanes.route("anthropic/claude-opus-5-5")
    client = Client.for(route, env: KEYS)
    material = Client.cached(client, instructions: "SYSTEM", input: [{ "role" => "user", "content" => "do it" }])
    body = JSON.parse(client.responses.compile(model: route.model, stream: false, max_output_tokens: 100,
      tools: [{ type: "function", name: "grep", description: "Search.", parameters: { type: "object", properties: {} } }],
      **material).payload)

    marker = { "type" => "ephemeral" }
    assert_equal marker, body.fetch("system").last["cache_control"], "the stable marker on the system block"
    assert_equal marker, body.fetch("messages").last.fetch("content").last["cache_control"], "the tail on the last message"
    assert_equal 2, JSON.generate(body).scan("\"cache_control\"").size, "two breakpoints, no more"
  end

  # THE KERNEL'S GATE, NOT HALF OF IT: Build places by the wire AND the row's `prompt_caching`
  # (`WireLowering.explicit_cache_breakpoints?`), so a profile that opts out, and every wire without
  # explicit breakpoints, is handed its material unchanged.
  def test_a_profile_the_kernel_would_not_mark_is_handed_its_material_unchanged
    input = [{ "role" => "user", "content" => "do it" }]
    opted_out = Client.client(lane: Lanes.route("anthropic/claude-opus-5-5").lane, model: "claude-opus-5-5", env: KEYS,
      capabilities: %w[streaming tool_calls])
    [opted_out, *%w[openrouter/z-ai/glm-5.3 openai_api/gpt-6.1-sol deepseek/deepseek-flash].map { |ref| Client.for(Lanes.route(ref), env: KEYS) }]
      .each do |client|
        assert_equal({ instructions: "SYSTEM", input: input }, Client.cached(client, instructions: "SYSTEM", input: input),
          client.execution_profile.profile_id)
      end
  end

  # THE KERNEL'S ROUTING KEY ON A BENCH CALL: Build keys a prompt cache on the wires that route by
  # one (`WireLowering.carries_cache_key?`), so a bench call on the sol lane carries the benchmark's
  # key from `E2E_BENCH_CACHE_KEY` and a call on any other wire never does — the gem refuses an
  # option its wire does not declare, so every lane's material compiles. No key named, none sent.
  def test_the_benchs_cache_key_rides_only_the_wires_that_route_by_one
    input = [{ "role" => "user", "content" => "do it" }]
    env = KEYS.merge("E2E_BENCH_CACHE_KEY" => "bench/arm/openai_api")
    keyed = %w[openai_api/gpt-6.1-sol].to_h { |ref| [ref, "bench/arm/openai_api"] }
    unkeyed = %w[openrouter/z-ai/glm-5.3 deepseek/deepseek-flash anthropic/claude-opus-5-5].to_h { |ref| [ref, nil] }

    keyed.merge(unkeyed).each do |ref, key|
      route = Lanes.route(ref)
      client = Client.for(route, env: env)
      material = Client.cached(client, instructions: "SYSTEM", input: input, env: env)
      body = JSON.parse(client.responses.compile(model: route.model, stream: false, max_output_tokens: 100, **material).payload)
      assert_equal({ "prompt_cache_key" => key }.compact, body.slice("prompt_cache_key"), ref)
    end

    sol = Client.for(Lanes.route("openai_api/gpt-6.1-sol"), env: KEYS)
    assert_equal({ instructions: "SYSTEM", input: input }, Client.cached(sol, instructions: "SYSTEM", input: input, env: KEYS),
      "no benchmark key, no routing key")
  end

  # The task probe sends its cache key on the wire and records the call's duration and usage.
  def test_the_benchmarks_cache_key_and_timing_reach_the_task_record
    route = Lanes.route("openai_api/gpt-6.1-sol")
    wire = RecordingAdapter.new(sol_answer)
    task = with_env("E2E_BENCH_CACHE_KEY" => "bench/arm/openai_api") do
      E2E::TaskBench::Sample.call(client: Client.for(route, env: KEYS, adapter: wire), route: route, style: "nexus",
        candidate: nil, objective: E2E::TaskBench::Objectives.find("G0"), index: 1,
        declared: E2E::TaskBench::DeclaredSet.function_definitions(style: "nexus"))
    end
    assert_equal 1, wire.requests.size
    assert_equal "bench/arm/openai_api", JSON.parse(wire.requests.first.fetch(:body))["prompt_cache_key"]
    assert_operator task.fetch("seconds"), :>=, 0
    assert_equal({ "input_tokens" => 900, "output_tokens" => 40 }, task.fetch("usage"))
  end

  # THE FACTS A SCREEN PRICES BY: the broker's BYOK discriminator (its `cost` is the whole bill only
  # on strict non-BYOK evidence) and the tier the Responses wire says it served (the settlement's
  # factor), each kept as the wire said it when the usage carries it, absent when it does not.
  def test_the_spend_keeps_the_byok_evidence_and_the_served_tier
    broker = facts(Lanes.route("openrouter/z-ai/glm-5.3"),
      { "id" => "gen-1", "object" => "chat.completion",
        "usage" => { "prompt_tokens" => 4_000, "completion_tokens" => 96, "cost" => 0.002, "is_byok" => false },
        "choices" => [{ "index" => 0, "finish_reason" => "stop", "message" => { "role" => "assistant", "content" => "ok" } }] })
    assert_equal({ "input_tokens" => 4_000, "output_tokens" => 96, "cost" => 0.002, "is_byok" => false }, broker.fetch("usage"))

    served = facts(Lanes.route("openai_api/gpt-6.1-sol"),
      { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [], "service_tier" => "flex",
        "usage" => { "input_tokens" => 900, "output_tokens" => 40 } })
    assert_equal({ "input_tokens" => 900, "output_tokens" => 40, "service_tier" => "flex" }, served.fetch("usage"))
  end

  # EVERY BILL A CONTRACT NAMES IS KEPT AS THE WIRE SENT IT: xAI bills in its own integer ticks
  # (`cost_in_usd_ticks`, 1 USD = 10^10) beside the counts, and the record keeps that integer under
  # the wire's name, so the lane's contract decodes the provider's bill exactly as the receipt
  # does; a call that reported no bill keeps none.
  def test_the_spend_keeps_xais_bill_as_the_integer_the_wire_sent
    route = Lanes.route("xai/grok-4.7")
    billed = facts(route, { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
      "usage" => { "input_tokens" => 900, "output_tokens" => 40, "cost_in_usd_ticks" => 600_000_000 } })
    assert_equal({ "input_tokens" => 900, "output_tokens" => 40, "cost_in_usd_ticks" => 600_000_000 }, billed.fetch("usage"))

    unbilled = facts(route, { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
      "usage" => { "input_tokens" => 900, "output_tokens" => 40 } })
    assert_equal({ "input_tokens" => 900, "output_tokens" => 40 }, unbilled.fetch("usage"))
  end

  # THE SPEND READS THE CACHE CLASSES THE RECEIPT READS (`UsageRecords::Tokens`): Anthropic reports
  # them beside `input_tokens`, so the input folds them in and each class is kept; the Responses and
  # chat wires report a cached share inside the input they already count.
  def test_the_spend_keeps_both_cache_classes_and_folds_anthropics_into_the_input
    anthropic = facts(Lanes.route("anthropic/claude-opus-5-5"),
      { "id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-opus-5-5",
        "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 20, "cache_read_input_tokens" => 9_000,
                     "cache_creation_input_tokens" => 150, "output_tokens" => 300 } })
    assert_equal({ "input_tokens" => 9_170, "output_tokens" => 300, "cache_read_tokens" => 9_000,
                   "cache_creation_tokens" => 150 }, anthropic.fetch("usage"))

    responses = facts(Lanes.route("openai_api/gpt-6.1-sol"),
      { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
        "usage" => { "input_tokens" => 9_000, "input_tokens_details" => { "cached_tokens" => 8_192 }, "output_tokens" => 40 } })
    assert_equal({ "input_tokens" => 9_000, "output_tokens" => 40, "cache_read_tokens" => 8_192 }, responses.fetch("usage"))
  end

  # THE PAID GATE, ONE COPY: explicit opt-in, never CI, development only, and every key the run
  # needs — refused before a request is built.
  def test_the_paid_gate_refuses_before_any_request
    assert Client.validate!(LIVE)
    assert Client.validate!(LIVE.merge("DEEPSEEK_API_KEY" => "k"), key_names: %w[DEEPSEEK_API_KEY])
    assert_raises(ArgumentError) { Client.validate!({ "RAILS_ENV" => "development" }) }
    assert_raises(ArgumentError) { Client.validate!(LIVE.merge("CI" => "true")) }
    assert_raises(ArgumentError) { Client.validate!(LIVE.merge("RAILS_ENV" => "test")) }
    missing = assert_raises(ArgumentError) { Client.validate!(LIVE, key_names: %w[DEEPSEEK_API_KEY]) }
    assert_equal "DEEPSEEK_API_KEY is not set", missing.message
    assert_raises(ArgumentError) { E2E::ManualOpenRouter.validate!(LIVE) }
    assert E2E::ManualOpenRouter.validate!(LIVE.merge("OPENROUTER_API_KEY" => "k"))
  end

  # THE KERNEL'S RETRY ON A MANUAL CALL: a lost connection, a timeout and an overloaded answer —
  # the model runner's own list — are asked again, each after ten seconds more than the last, and
  # every retry is kept as the error it answered and the pause it took; the third call's error is
  # the call's. A provider that answered and refused, and a fault of the harness, are not retried.
  def test_a_transient_failure_is_retried_on_the_kernels_list_within_the_budget
    pauses = []
    pause = ->(seconds) { pauses << seconds }
    reset = SimpleInference::ConnectionError.new("Connection reset by peer")

    answered = Client.retrying(pause: pause, &flaky(reset, SimpleInference::TimeoutError.new("Net::ReadTimeout")))
    assert_equal [:answered, nil], [answered.result, answered.error]
    assert_equal [{ "error" => "SimpleInference::ConnectionError: Connection reset by peer", "pause_seconds" => 10 },
                  { "error" => "SimpleInference::TimeoutError: Net::ReadTimeout", "pause_seconds" => 20 }], answered.retries
    assert_equal [10, 20], pauses
    assert_equal({ "retries" => answered.retries, "seconds" => answered.seconds }, answered.facts)

    asked = 0
    spent = Client.retrying(pause: ->(_seconds) { }) do
      asked += 1
      raise SimpleInference::ConnectionError, "reset #{asked}"
    end
    assert_equal [3, nil, "reset 3"], [asked, spent.result, spent.error.message], "three calls, the last one's error"
    assert_equal ["SimpleInference::ConnectionError: reset 1", "SimpleInference::ConnectionError: reset 2"],
      spent.retries.map { |entry| entry.fetch("error") }

    overloaded = Client.retrying(pause: ->(_seconds) { }, &flaky(http_error(503)))
    assert_equal [:answered, 1], [overloaded.result, overloaded.retries.length]

    [http_error(400), NoMethodError.new("undefined method 'tool_calls' for nil")].each do |error|
      failed = Client.retrying(pause: ->(_seconds) { flunk "#{error.class} is not retried" }, &flaky(error))
      assert_equal [nil, error, []], [failed.result, failed.error, failed.retries]
      assert_equal({ "seconds" => failed.seconds }, failed.facts, "no retry to keep; the call's own seconds")
    end
  end

  # THE CALL'S OWN CLOCK: `seconds` is the monotonic span of the attempt that answered — the call
  # a draw's wall is made of — never the failed attempts or the pauses before it, which the retries
  # already name; a call whose last attempt failed keeps that attempt's span. A simulated clock the
  # calls and the pauses advance, so nothing here sleeps.
  def test_the_seconds_span_the_answering_attempt_alone
    now = 100.0
    clock = -> { now }
    pause = ->(seconds) { now += seconds }
    calls = [[4.5, SimpleInference::ConnectionError.new("Connection reset by peer")], [6.75, nil]].each
    answered = Client.retrying(pause: pause, clock: clock) do
      spent, error = calls.next
      now += spent
      error ? raise(error) : :answered
    end
    assert_equal [:answered, 6.75], [answered.result, answered.seconds], "not 4.5 + the 10 s pause + 6.75"
    assert_equal 6.75, answered.facts.fetch("seconds")

    failed = Client.retrying(pause: pause, clock: clock) do
      now += 2.0
      raise http_error(400)
    end
    assert_equal [2.0, { "seconds" => 2.0 }], [failed.seconds, failed.facts]
  end

  # A FAILED TLS EXCHANGE IS A LOST CONNECTION: the model runner's transport raises it as one, so
  # the product retries it; the gem's default transport reads it the same way for manual calls.
  # A loopback listener that answers the client's TLS hello in plain text is that failure, offline.
  def test_a_failed_tls_exchange_reaches_a_manual_client_as_a_lost_connection
    server = TCPServer.new("127.0.0.1", 0)
    listener = Thread.new do
      socket = server.accept
      socket.readpartial(1024)
      socket.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
      socket.close
    end
    lane = Lanes::Lane.new(provider_id: "openrouter", format: "openrouter_chat",
      base_url: "https://127.0.0.1:#{server.addr[1]}/api", key_name: "OPENROUTER_API_KEY")
    client = Client.client(lane: lane, model: "z-ai/glm-5.3-flash", env: KEYS, timeout: 10)

    error = assert_raises(SimpleInference::ConnectionError) do
      client.responses.create(model: "z-ai/glm-5.3-flash", input: [{ "role" => "user", "content" => "x" }], max_output_tokens: 16)
    end
    assert_instance_of OpenSSL::SSL::SSLError, error.cause
    assert_equal error.cause.message, error.message
    assert ModelInvocations::ApplyResult.transient_error?(error), "the kernel's list reads it as transient"
  ensure
    listener&.kill
    server&.close
  end

  private

    # A call that raises each of `errors` in turn, then answers.
    def flaky(*errors)
      pending = errors.dup
      -> { pending.empty? ? :answered : raise(pending.shift) }
    end

    def http_error(status)
      SimpleInference::HTTPError.new("HTTP #{status}",
        response: SimpleInference::Response.new(status: status, headers: {}, body: nil, raw_body: ""))
    end

    # A completed Responses answer with recorded usage and no tool call.
    def sol_answer
      { "id" => "resp_1", "object" => "response", "status" => "completed", "output" => [],
        "usage" => { "input_tokens" => 900, "output_tokens" => 40 } }
    end

    # The block under `values` in the process environment, which the benches' callers read; each
    # name restored after.
    def with_env(values)
      saved = values.to_h { |name, _| [name, ENV[name]] }
      values.each { |name, value| ENV[name] = value }
      yield
    ensure
      saved&.each { |name, value| ENV[name] = value }
    end

    # One call over the lane's real wire, answered by `body` through the recording transport.
    def facts(route, body)
      result = Client.for(route, env: KEYS, adapter: RecordingAdapter.new(body))
        .responses.create(model: route.model, input: [{ "role" => "user", "content" => "x" }], max_output_tokens: 4_096)
      Client.facts(result, route.lane)
    end
end
