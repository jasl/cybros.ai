require "support/daemon_loop_helpers"

class DaemonIngressInputsTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_queue_returns_the_acceptance_without_waiting_for_materialization
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation(model: "dev/mock-text").dig("conversation", "public_id")

    daemon.context.instance_variable_get(:@loops).define_singleton_method(:await_materialization) do |*|
      raise "A queued channel input must not wait for materialization"
    end
    answer = core.say(id, "hello", mode: "queue", wait: false, speaker_actor_public_id: "actor-1",
      idempotency_key: "telegram-message-1")

    assert_equal "cin-1", answer.dig("input", "public_id")
    assert_equal true, answer.fetch("pending")
    assert_equal "actor-1", api.conversation_inputs.last.dig("input", "speaker_actor_public_id")
    assert_equal "direct_reply", api.conversation_inputs.last.dig("input", "kind")
  end

  def test_guard_and_caller_inline_preserve_the_existing_surface_preface
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation(model: "dev/mock-text").dig("conversation", "public_id")
    core.say(id, "before", mode: "queue", wait: false)
    original = api.conversation_inputs.last.fetch("input").fetch("inline")
    refute_empty original
    context = [{ "role" => "user", "position" => "lead", "text" => "Earlier room messages" }]

    core.say(id, "correction", expected_steering_loop_public_id: "loop-1", inline: context, wait: false)
    input = api.conversation_inputs.last.fetch("input")
    assert_equal "loop-1", input.fetch("expected_steering_loop_public_id")
    assert_equal "steer", input.fetch("delivery_mode")
    assert_equal original + context, input.fetch("inline")
  end

  def test_observation_is_a_visible_user_message_without_model_or_reply_configuration
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation.dig("conversation", "public_id")

    answer = core.say(id, "background context", mode: "queue", kind: "message", wait: false,
      speaker_actor_public_id: "actor-1", idempotency_key: "telegram-observation-1")

    assert_equal "cin-1", answer.dig("input", "public_id")
    refute answer.key?("loop")
    refute answer.key?("pending")
    assert_equal({ "kind" => "message", "role" => "user", "text" => "background context",
      "delivery_mode" => "queue", "visible_in_context" => true, "speaker_actor_public_id" => "actor-1" },
      api.conversation_inputs.last.fetch("input"))
  end

  def test_group_answerer_receives_explicit_restrictions_through_core_and_the_public_input_door
    api = kernel_api(conversation_events: [])
    api.stock_principals([{ "public_id" => "group-profile", "handle" => "telegram-group", "kind" => "agent",
      "display_name" => "Telegram group", "agent_identifier" => nil, "steward_public_id" => "steward-1" }])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation(model: "dev/mock-text", agent: "group-profile", compose: false).dig("conversation", "public_id")

    [["read"], []].each do |names|
      core.say(id, "Use these tools", mode: "queue", wait: false, tool_names: names, approval_mode: "rules")
      input = api.conversation_inputs.last.fetch("input")
      assert_equal names, input.fetch("tool_names")
      assert_equal "rules", input.fetch("approval_mode")
      refute input.key?("inline"), "the personal profile's environment stays out of the group prompt"
    end

    core.say(id, "Use the group defaults", mode: "queue", wait: false)
    input = api.conversation_inputs.last.fetch("input")
    refute input.key?("tool_names"), "omission does not copy the personal profile's tier"
    refute input.key?("approval_mode")
  end

  def test_explicit_tools_reach_the_target_validator_without_local_tier_filtering
    api = kernel_api(conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation(model: "dev/mock-text", compose: false).dig("conversation", "public_id")

    core.say(id, "Explicit tools", mode: "queue", wait: false, tool_names: ["compose", "target_tool"])
    assert_equal ["compose", "target_tool"], api.conversation_inputs.last.dig("input", "tool_names")

    core.say(id, "Use defaults", mode: "queue", wait: false)
    assert_equal names_without_compose, api.conversation_inputs.last.dig("input", "tool_names")
  end

  def test_a_tool_subset_refusal_keeps_the_kernels_validation_response
    refusal = CybrosAgent::Response.new(status: 422, headers: {},
      body: { "error" => { "code" => "validation_failed", "message" => "tool_names contains an undeclared tool" } })
    api = kernel_api(conversation_events: [], conversation_input: refusal)
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation(model: "dev/mock-text").dig("conversation", "public_id")

    error = assert_raises(Rho::Core::Refused) { core.say(id, "Use this tool", tool_names: ["undeclared_tool"], wait: false) }
    assert_equal 422, error.status
    assert_equal "validation_failed", error.code
    assert_match(/tool_names contains an undeclared tool/, error.message)
  end

  def test_loop_input_refuses_an_explicit_tool_subset_instead_of_dropping_it
    api = kernel_api(conversation_events: [])
    daemon = member_ready(boot(config: tiered, realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    store.remember(loop_host("al-solo"), workspace: "ws-1")

    error = assert_raises(Rho::Core::Refused) { core.say("al-solo", "No tools", tool_names: [], wait: false) }
    assert_equal 400, error.status
    assert_match(/no tool_names/, error.message)
    assert_empty api.loop_inputs
  end

  def test_observation_refuses_reply_only_fields_and_non_queue_delivery
    api = NexusDoubles::FakeAgentApi.new
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    core = Rho::Core.new(home: daemon.home)
    id = core.open_conversation.dig("conversation", "public_id")

    [{ mode: "steer" }, { mode: "queue", model: "dev/mock-text" },
      { mode: "queue", approval_mode: "bypass" }, { mode: "queue", tool_names: [] },
      { mode: "queue", to: "@other" }].each do |options|
      error = assert_raises(Rho::Core::Refused) { core.say(id, "context", kind: "message", **options) }
      assert_equal 400, error.status
    end
    assert_empty api.conversation_inputs
  end
end
