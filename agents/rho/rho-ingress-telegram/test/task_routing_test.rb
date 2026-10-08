require "support/runtime"

class TelegramTaskRoutingTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
  end

  def test_existing_private_route_needs_no_duplicate_route_key_to_accept_a_new_request
    receive(telegram_message(1, "/new"))
    @state.change { |document| document.fetch("routes").fetch("1:0").delete("route_key") }

    receive(telegram_message(2, "Continue in this conversation"))

    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:2:input").fetch(:conversation_id)
    request = @state.read.fetch("requests").fetch("telegram:42:2:input")
    assert_equal ["1:0", "input-1"], request.values_at("route_key", "input_id")
    refute @state.read.fetch("deliveries").key?("control:2")
    assert_nil @state.read["pending_update"]
    assert_equal 3, @state.read.fetch("offset")
  end

  def test_other_group_members_cannot_stop_steer_or_continue_a_requesters_task
    receive(mention(1, user: 2))
    receive(mention(2, user: 3))
    ["/stop", "/steer change A", "Continue A"].each_with_index do |text, index|
      receive(telegram_message(index + 3, text, user: 3, chat: -10, topic: 4, reply_to: 1, reply_user: 2))
      assert_includes feedback(index + 3), "Only this task's requester or the bot owner"
    end
    assert_equal 2, @bridge.inputs.length
    assert_empty @bridge.stops

    receive(telegram_message(6, "/steer keep A's goal", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    input = @bridge.inputs.fetch("telegram:42:6:input")
    assert_equal "conversation-1", input.fetch(:conversation_id)
    assert_equal "loop-1", input.fetch(:expected_steering_run_public_id)
    receive(telegram_message(7, "/stop", chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("-10:4:3").fetch("current")
  end

  def test_unreplied_stop_selects_only_the_callers_known_execution
    receive(mention(1, user: 2))
    receive(mention(2, user: 3))
    receive(telegram_message(3, "/stop", user: 2, chat: -10, topic: 4))
    receive(telegram_message(4, "/stop", user: 3, chat: -10, topic: 4))

    assert_equal [["loop-1", "run", "workspace-home"], ["loop-2", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_original_message_reply_after_new_and_restart_keeps_the_original_task
    receive(mention(1, user: 2))
    receive(telegram_message(2, "/new", user: 2, chat: -10, topic: 4))
    receive(mention(3, user: 2))
    @runtime = runtime
    receive(telegram_message(4, "/stop", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))
    receive(telegram_message(5, "A follow-up to the old task", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:5:input").fetch(:conversation_id)
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("-10:4:2").fetch("current")
    assert_equal 2, @bridge.opened.length
  end

  def test_unknown_bot_reply_does_not_guess_the_current_task
    receive(mention(1, user: 2))
    receive(telegram_message(2, "continue", user: 2, chat: -10, topic: 4, reply_to: 999))
    receive(telegram_message(3, "/stop", user: 2, chat: -10, topic: 4, reply_to: 999))

    assert_equal 1, @bridge.inputs.length
    assert_empty @bridge.stops
    assert_includes feedback(2), "not linked to a known task"
    assert_includes feedback(3), "not linked to a known task"
  end

  def test_formal_reply_retains_the_original_request_link_without_an_acceptance_receipt
    receive(mention(1, user: 2))
    @bridge.turn_rows["conversation-1"] = [turn(0, "A formal answer")]
    @runtime.tick
    message_id = @client.last_message_id
    assert_equal "telegram:42:1:input", @state.read.fetch("messages").fetch("-10:4:#{message_id}")
    formal_send = @client.calls.find { |method, params| method == "sendMessage" && params[:text] == "A formal answer" }
    assert_equal({ message_id: 1, allow_sending_without_reply: true }, formal_send.last.fetch(:reply_parameters))
    @runtime = runtime
    receive(telegram_message(2, "/stop", chat: -10, topic: 4, reply_to: message_id))
    assert_equal ["loop-1"], @bridge.stops
  end

  def test_queued_request_recovers_its_materialized_turn_and_original_loop
    @bridge.defer_inputs = true
    receive(mention(1, user: 2))
    request = @state.read.fetch("requests").fetch("telegram:42:1:input")
    assert_equal "input-1", request.fetch("input_id")
    assert_nil request["run_id"]
    @bridge.event_rows["conversation-1"] = [{ "type" => "input_materialized", "cursor" => "1", "sequence" => 1,
      "payload" => { "input_public_id" => "input-1", "turn_public_id" => "turn-0" } },
      { "type" => "turn_status", "cursor" => "2", "sequence" => 2,
        "payload" => { "turn_public_id" => "turn-0", "run_public_id" => "original-loop" } }]
    @bridge.turn_rows["conversation-1"] = [turn(0, "", status: "running").merge("run_public_id" => "original-loop")]
    receive(telegram_message(2, "/new", user: 2, chat: -10, topic: 4))
    @runtime = runtime
    receive(telegram_message(3, "/stop", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_equal [["original-loop", "run", "workspace-home"]], @bridge.stop_calls
    recovered = @state.read.fetch("requests").fetch("telegram:42:1:input")
    assert_equal ["turn-0", "original-loop"], recovered.values_at("turn_id", "run_id")
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("-10:4:2").fetch("current")
  end

  def test_late_steering_refusal_is_consumed_without_creating_a_replacement_request
    receive(mention(1, user: 2))
    attempts = []
    @bridge.define_singleton_method(:submit) do |id, **request|
      attempts << [id, request]
      raise Rho::Core::Refused.new("Selected execution is no longer steering", status: 409, code: "steering_target_changed")
    end
    receive(telegram_message(2, "/steer late instruction", user: 2, chat: -10, topic: 4, reply_to: 1, reply_user: 2))

    assert_equal "loop-1", attempts.first.last.fetch(:expected_steering_run_public_id)
    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.opened.length
    assert_equal 3, @state.read.fetch("offset")
    assert_nil @state.read["pending_update"]
    assert_includes feedback(2), "Selected execution is no longer steering"
  end

  def test_steer_retry_keeps_the_request_selected_before_a_lost_response
    receive(mention(1, user: 2))
    @bridge.fail_input = true
    update = telegram_message(2, "/steer original task", user: 2, chat: -10, topic: 4)
    assert_raises(Rho::ConnectionError) { receive(update) }
    # A previously queued media request can materialize while control IO retries.
    @state.change do |document|
      document.fetch("requests")["later-request"] = document.fetch("requests").fetch("telegram:42:1:input").merge(
        "input_id" => "later-input", "turn_id" => "later-turn", "run_id" => "later-loop")
    end
    submitted = []
    original = @bridge.method(:submit)
    @bridge.define_singleton_method(:submit) { |id, **request| submitted << request; original.call(id, **request) }
    @runtime = runtime
    receive(update)

    assert_equal ["loop-1"], submitted.map { |request| request.fetch(:expected_steering_run_public_id) }
    assert_nil @state.read["pending_update"]
    assert_equal 2, @bridge.inputs.length
  end

  def test_busy_task_observation_is_separate_and_does_not_fill_its_input_queue
    @client.admin = true
    receive(telegram_message(1, "/observe on", chat: -10, topic: 4))
    receive(mention(2, user: 2))
    40.times do |index|
      receive(telegram_message(index + 3, "Background #{index}", user: 3, chat: -10, topic: 4))
    end
    receive(mention(43, user: 3))

    task_a = @bridge.inputs.values.select { |row| row.fetch(:conversation_id) == "conversation-1" }
    observed = @bridge.inputs.values.select { |row| row[:observe] }
    task_b = @bridge.inputs.fetch("telegram:42:43:input")
    assert_equal 1, task_a.length
    assert_equal 40, observed.length
    assert_equal ["memory-1"], observed.map { |row| row.fetch(:conversation_id) }.uniq
    assert_equal "conversation-2", task_b.fetch(:conversation_id)
    assert_includes task_b.fetch(:inline).first.fetch("text"), "Background 39"
    assert_empty @bridge.stops
    assert_equal 44, @state.read.fetch("offset")
    refute @state.read.fetch("routes").values.any? { |row| row.fetch("conversations").key?("memory-1") }
    assert_equal ["control:1"], @state.read.fetch("deliveries").keys
  end

  def test_group_admin_role_never_grants_bot_management_or_approval
    @client.admin = true
    ["/observe on", "/model vendor/model", "/access users add 9", "/ignore add 2", "/approve unknown"].each_with_index do |text, index|
      receive(telegram_message(index + 1, text, user: 3, chat: -10, topic: 4))
      assert_includes feedback(index + 1), "Only the bot owner"
    end
    assert_empty @bridge.decisions
    refute @state.read.fetch("rooms").dig("-10:4", "observe")
    refute_includes @state.read.fetch("access").fetch("allowed_users"), "9"
    assert_empty @state.read.fetch("access").fetch("ignored_users")
  end

  def test_only_requester_or_owner_answers_and_only_owner_approves_child_tasks
    receive(mention(1, user: 2))
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "question", "kind" => "ask", "question" => "Which choice?" }]
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    receive(telegram_message(2, "/answer #{question} B's choice", user: 3, chat: -10, topic: 4))
    assert_empty @bridge.decisions
    assert_includes feedback(2), "Only this task's requester or the bot owner"
    receive(telegram_message(3, "/answer #{question} A's choice", user: 2, chat: -10, topic: 4))
    assert_equal [["answer", "child-loop", "question", "A's choice", "workspace-home"]], @bridge.decisions

    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "approval", "kind" => "approval", "question" => "Run this tool?" }]
    @now += 5
    @runtime.tick
    approval = @state.read.fetch("questions").find { |_id, row| row.fetch("kind") == "approval" }.first
    receive(telegram_message(4, "/approve #{approval}", user: 2, chat: -10, topic: 4))
    assert_equal 1, @bridge.decisions.length
    assert_includes feedback(4), "Only the bot owner"
    receive(telegram_message(5, "/approve #{approval}", chat: -10, topic: 4))
    assert_equal ["approve", "child-loop", "approval", "workspace-home"], @bridge.decisions.last
  end

  def test_derived_background_answer_still_selects_the_original_request_and_loop
    receive(mention(1, user: 2))
    @state.change { |document| document.fetch("deliveries").clear }
    @bridge.current = { "status" => "completed", "run_public_id" => "background-loop" }
    @bridge.event_rows["conversation-1"] = [
      { "type" => "input_accepted", "cursor" => "1", "sequence" => 1,
        "payload" => { "input_public_id" => "background-input", "origin" => "task_result", "run_public_id" => "loop-1" } },
      { "type" => "input_materialized", "cursor" => "2", "sequence" => 2,
        "payload" => { "input_public_id" => "background-input", "turn_public_id" => "turn-1" } },
      { "type" => "turn_status", "cursor" => "3", "sequence" => 3,
        "payload" => { "turn_public_id" => "turn-1", "run_public_id" => "background-loop" } },
    ]
    @bridge.turn_rows["conversation-1"] = [turn(0, "Original answer"), turn(1, "Later background answer")]
    @runtime.tick
    @now += 4
    @runtime.tick

    response = @client.calls.find { |method, params| method == "sendMessage" && params[:text] == "Later background answer" }
    assert_equal 1, response.last.fetch(:reply_parameters).fetch(:message_id)
    message_id = @client.last_message_id
    assert_equal "telegram:42:1:input", @state.read.fetch("messages").fetch("-10:4:#{message_id}")
    @runtime = runtime
    receive(telegram_message(2, "/stop", user: 3, chat: -10, topic: 4, reply_to: message_id))
    assert_empty @bridge.stops
    assert_includes feedback(2), "Only this task's requester or the bot owner"
    receive(telegram_message(3, "/stop", chat: -10, topic: 4, reply_to: message_id))

    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
  end

  private

    def mention(id, user:)
      telegram_message(id, "@rho_bot task #{id}", user: user, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
