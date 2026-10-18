$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "support/bench_client"
require "support/task_bench"

# Paid probes and offline rehearsals share the client's real wire and parsing path.
# Fake requests use a placeholder key and canned responses, including injected failures.
class BenchClientHarnessTest < Minitest::Test
  C = E2E::BenchClient
  FAKE = { "E2E_BENCH_CLIENT" => "fake" }.freeze
  NO_PAUSE = ->(_seconds) { }

  def test_a_real_client_is_the_manual_clients_own
    route = manual_route
    client = C.for(route, env: { "E2E_BENCH_CLIENT" => "real", "OPENROUTER_API_KEY" => "sk-or-placeholder" })
    assert_instance_of SimpleInference::HTTPAdapters::Default, client.adapter
    assert_equal "sk-or-placeholder", client.config.api_key
  end

  def test_an_unnamed_client_is_real_and_an_unknown_one_is_refused
    route = manual_route
    assert_equal "sk-or-placeholder", C.for(route, env: { "OPENROUTER_API_KEY" => "sk-or-placeholder" }).config.api_key
    error = assert_raises(ArgumentError) { C.for(route, env: { "E2E_BENCH_CLIENT" => "Fake" }) }
    assert_includes error.message, "E2E_BENCH_CLIENT"
  end

  def test_fake_refs_are_validated_and_cannot_reach_a_real_transport
    assert_raises(ArgumentError) { C.route("fake/unknown", env: FAKE) }
    error = assert_raises(ArgumentError) { C.route("fake/chat-a", env: {}) }
    assert_includes error.message, "E2E_BENCH_CLIENT=fake"
    error = assert_raises(ArgumentError) { C.for(C.route("fake/chat-a", env: FAKE), env: {}) }
    assert_includes error.message, "E2E_BENCH_CLIENT=fake"
  end

  # A fake job reads no key: the one the environment holds never reaches the client.
  def test_a_fake_client_carries_a_placeholder_key_whatever_the_environment_holds
    route = C.route("fake/chat-a", env: FAKE)
    client = C.for(route, env: FAKE.merge("OPENROUTER_API_KEY" => "sk-or-v1-real-looking"))
    assert_equal C::FAKE_KEY, client.config.api_key
    assert_kind_of E2E::FakeBenchAdapter, client.adapter
  end

  def test_the_paid_gate_is_the_manual_clients_and_a_fake_job_skips_it
    assert C.gate(FAKE, key_names: ["OPENROUTER_API_KEY"])
    error = assert_raises(ArgumentError) { C.gate({}, key_names: ["OPENROUTER_API_KEY"]) }
    assert_includes error.message, "E2E_LIVE=1"
  end

  # The task probe's two-step draw on every wire: where the bench declared rho's set,
  # the fake's first answer is a read (`ls`), answered from the objective's fixture, and its answer
  # once a read came back is a `task` call — the draw's scored second message. The broker's spend
  # carries its `is_byok`, as its wire does.
  def test_a_task_draw_reads_first_then_hands_out_a_task_on_each_wire
    declared = E2E::TaskBench::DeclaredSet.function_definitions(style: "nexus")
    %w[fake/chat-b fake/responses fake/messages].each do |ref|
      route = C.route(ref, env: FAKE)
      sample = E2E::TaskBench::Sample.call(client: C.for(route, env: FAKE), route: route, style: "nexus", candidate: nil,
        objective: E2E::TaskBench::Objectives.find("SP3A"), index: 1, declared: declared, pause: NO_PAUSE)
      assert_nil sample["error"], "#{ref}: #{sample.inspect[0, 300]}"
      assert_equal [[{ "ls" => 1 }, true], [{ "delegate_task" => 1 }, false]], sample.fetch("messages").map { |message| message.values_at("called", "read_class") }, ref
      assert_equal 2, sample["scored_message"], ref
    end

    broker = C.route("fake/chat-b", env: FAKE)
    sample = E2E::TaskBench::Sample.call(client: C.for(broker, env: FAKE), route: broker, style: "nexus", candidate: nil,
      objective: E2E::TaskBench::Objectives.find("SP3A"), index: 1, declared: declared, pause: NO_PAUSE)
    assert_equal [false, false, false], [*sample.fetch("messages").map { |message| message.dig("usage", "is_byok") }, sample.dig("usage", "is_byok")]
  end

  # A call the client's retry reaches on a later attempt is waited out, never a storm event, so the
  # storm the rehearsal injects is every call from the third on unreached however often it is asked.
  def test_storm_leaves_every_call_from_the_third_on_unreached_on_every_attempt
    adapter = E2E::FakeBenchAdapter.new(inject: %w[storm])
    statuses = Array.new(6) { adapter.call(request).fetch(:status) }
    assert_equal [200, 200, 503, 503, 503, 503], statuses
  end

  def test_fault_raises_a_harness_fault_class_on_the_second_call
    adapter = E2E::FakeBenchAdapter.new(inject: %w[fault])
    adapter.call(request)
    assert_raises(NoMethodError) { adapter.call(request) }
  end

  def test_spend_answers_the_wires_spend_usage
    adapter = E2E::FakeBenchAdapter.new(inject: %w[spend])
    body = JSON.parse(adapter.call(request).fetch(:body))
    assert_equal 2_000_000, body.dig("usage", "completion_tokens")
  end

  def test_stall_sleeps_before_the_fifth_call
    slept = []
    adapter = E2E::FakeBenchAdapter.new(inject: %w[stall], stall_seconds: 7, sleep: ->(seconds) { slept << seconds })
    5.times { adapter.call(request) }
    assert_equal [7], slept
  end

  def test_an_injection_the_fake_does_not_know_is_refused
    error = assert_raises(ArgumentError) { C.for(C.route("fake/chat-a", env: FAKE), env: FAKE.merge("E2E_BENCH_FAKE_INJECT" => "flood")) }
    assert_includes error.message, "flood"
  end

  private

    def manual_route
      lane = E2E::ProviderLanes::Lane.new(provider_id: "fixture", format: "openrouter_chat",
        base_url: "https://provider.example", key_name: "OPENROUTER_API_KEY")
      E2E::ProviderLanes::Route.new(ref: "fixture/text", lane: lane, model: "text")
    end

    def request
      { url: "https://fake.invalid/chat/completions",
        body: JSON.generate("tools" => [{ "type" => "function", "function" => { "name" => "read_file" } }]) }
    end
end
