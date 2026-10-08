require "support/runtime"

class TelegramOperationPermissionsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_owner_keeps_the_declared_capabilities_in_private_and_group_chats
    receive(telegram_message(1, "Write my report"))
    receive(group_message(2, user: 1))

    assert_equal 2, @bridge.inputs.length
    @bridge.inputs.each_value { |input| refute input.key?(:tool_names) }
  end

  def test_nonowner_uses_the_isolated_profile_in_private_and_group_chats
    @bridge.declared_tools[false] = %w[bash read write grep delegate_task spawn memory_read]
    @bridge.declared_tools[true] = %w[ls edit web_fetch code wait ask navigate screenshot read_process]
    receive(telegram_message(1, "Read this report", user: 2))
    receive(group_message(2))

    assert_equal %w[ls web_fetch code wait ask], input(1).fetch(:tool_names)
    assert_equal true, input(1).fetch(:isolated)
    assert_equal %w[ls web_fetch code wait ask], input(2).fetch(:tool_names)
    assert_equal [["conversation-1", true, "workspace-home"], ["conversation-2", true, "workspace-home"]], @bridge.tool_selections
  end

  def test_telegram_administrator_status_does_not_grant_owner_tools
    @client.admin = true
    @bridge.declared_tools[true] = %w[read bash write edit start_process evaluate image_generate]
    receive(group_message(1))

    assert_equal ["read"], input(1).fetch(:tool_names)
  end

  def test_empty_read_only_intersection_is_explicit_and_never_means_the_whole_profile
    @bridge.declared_tools[true] = %w[bash write]
    receive(group_message(1))

    assert_equal [], input(1).fetch(:tool_names)
  end

  def test_lost_acceptance_and_restart_keep_the_nonowner_input_restricted
    @bridge.declared_tools[true] = %w[read bash]
    @bridge.fail_input = true
    update = group_message(1)
    assert_raises(Rho::ConnectionError) { receive(update) }
    @runtime = runtime
    receive(update)

    assert_equal 1, @bridge.inputs.length
    assert_equal ["read"], input(1).fetch(:tool_names)
    assert_nil @state.read["pending_update"]
  end

  def test_replying_after_an_owner_continues_the_request_does_not_grant_owner_tools
    @bridge.declared_tools[true] = %w[read bash write]
    receive(group_message(1))
    receive(telegram_message(2, "Owner's additional request", chat: -10, reply_to: 1, reply_user: 2))
    receive(telegram_message(3, "My follow-up", user: 2, chat: -10, reply_to: 2, reply_user: 1))

    assert_equal ["read"], input(1).fetch(:tool_names)
    refute input(2).key?(:tool_names)
    assert_equal ["read"], input(3).fetch(:tool_names)
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }.uniq
  end

  def test_pending_inputs_and_following_text_are_restricted_when_admitted_after_restart
    @bridge.declared_tools[true] = %w[read delegate_task bash write]
    @bridge.define_singleton_method(:stage_media) { |**| "image-upload" }
    @client.define_singleton_method(:download) { |*_, **| "image bytes" }
    photo = group_message(1)
    photo.fetch("message")["photo"] = [{ "file_id" => "photo", "file_size" => 10 }]
    receive(photo)
    receive(group_message(2))
    assert_empty @bridge.inputs

    @runtime = runtime
    @runtime.tick
    @now += 5
    @runtime.tick

    assert_equal 2, @bridge.inputs.length
    assert_equal ["image-upload"], input(1).fetch(:upload_public_ids)
    @bridge.inputs.each_value { |request| assert_equal %w[read delegate_task], request.fetch(:tool_names) }
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_nonowner_can_edit_only_an_explicitly_read_only_pending_input
    @bridge.defer_inputs = true
    receive(group_message(1))
    @bridge.queue_rows["conversation-1"] = [{ "public_id" => "input-1", "state" => "pending", "text" => "Original",
      "tool_names" => ["read"] }]
    receive(telegram_message(2, "/queue", user: 2, chat: -10))
    receive(telegram_message(3, "/queue edit 1 Corrected", user: 2, chat: -10))
    assert_equal [[:edit, "conversation-1", "input-1", "Corrected", "workspace-home"]], @bridge.queue_writes

    @bridge.queue_rows.fetch("conversation-1").first["tool_names"] = ["read", "write"]
    receive(telegram_message(4, "/queue edit 1 Write a file", user: 2, chat: -10))
    @bridge.queue_rows.fetch("conversation-1").first.delete("tool_names")
    receive(telegram_message(5, "/queue edit 1 Delete a file", user: 2, chat: -10))

    assert_equal 1, @bridge.queue_writes.length
    [4, 5].each { |id| assert_includes reply(id), "read-only" }
    receive(telegram_message(6, "/queue cancel 1", user: 2, chat: -10))
    assert_equal [:cancel, "conversation-1", "input-1", "workspace-home"], @bridge.queue_writes.last
  end

  def test_nonowner_steering_requires_the_selected_execution_to_be_read_only
    receive(group_message(1))
    @bridge.execution_tools["loop-1"] = ["read", "write"]
    receive(telegram_message(2, "/steer Change it", user: 2, chat: -10))
    assert_equal 1, @bridge.inputs.length
    assert_includes reply(2), "verified read-only tool set"
    @bridge.execution_tools["loop-1"] = nil
    receive(telegram_message(3, "/steer Retry", user: 2, chat: -10))
    assert_equal 1, @bridge.inputs.length
    @bridge.execution_tools["loop-1"] = %w[read delegate_task]
    receive(telegram_message(4, "/steer Keep reading", user: 2, chat: -10))
    assert_equal "loop-1", input(4).fetch(:expected_steering_run_public_id)
    assert_equal "steer", input(4).fetch(:mode)
  end

  def test_nonowner_cannot_answer_a_high_privilege_or_unverifiable_question_but_owner_can
    receive(group_message(1))
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "question", "kind" => "ask", "question" => "Which file?" }]
    @runtime.tick
    @now += 5
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    @bridge.execution_tools["child-loop"] = %w[read bash]
    receive(telegram_message(2, "/answer #{question} Delete it", user: 2, chat: -10))
    assert_empty @bridge.decisions
    assert_includes reply(2), "verified read-only tool set"
    @bridge.execution_tools["child-loop"] = nil
    receive(telegram_message(3, "/answer #{question} Retry", user: 2, chat: -10))
    assert_empty @bridge.decisions
    message_id = @state.read.fetch("questions").fetch(question).fetch("message_ids").first
    receive(telegram_message(4, "An answer by reply", user: 2, chat: -10, reply_to: message_id, reply_user: 42))
    assert_empty @bridge.decisions
    assert_equal 1, @bridge.inputs.length
    assert_includes reply(4), "verified read-only tool set"
    receive(telegram_message(5, "/answer #{question} Owner's answer", chat: -10))
    assert_equal [["answer", "child-loop", "question", "Owner's answer", "workspace-home"]], @bridge.decisions
  end

  def test_local_attention_does_not_attempt_to_read_a_missing_model_task
    receive(group_message(1))
    @bridge.pending_rows = [{ "run_public_id" => nil, "task_key" => nil, "kind" => "local", "question" => "Use the CLI." }]
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    @bridge.define_singleton_method(:read_only_execution?) { |*, **| raise "Local attention has no model task" }
    receive(telegram_message(2, "/answer #{question} An answer", user: 2, chat: -10))

    assert_empty @bridge.decisions
    assert_includes reply(2), "attention in the rho CLI"
  end

  private

    def group_message(id, user: 2)
      telegram_message(id, "@rho_bot Read and summarize", user: user, chat: -10,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def input(id) = @bridge.inputs.fetch("telegram:42:#{id}:input")
    def reply(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
end
