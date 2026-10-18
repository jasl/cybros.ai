require "support/runtime"

class TelegramOperationPermissionsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_owner_and_members_use_the_same_bot_declaration_without_ingress_tool_overrides
    receive(telegram_message(1, "Write my report"))
    receive(group_message(2))

    assert_equal 2, @bridge.inputs.length
    @bridge.inputs.each_value do |request|
      refute request.key?(:tool_names)
      refute request.key?(:isolated)
      refute request.key?(:approval_mode)
    end
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |request| request.fetch(:conversation_id) }.uniq
    assert_equal %w[speaker-1 speaker-2], @bridge.inputs.values.map { |request| request.fetch(:speaker) }
  end

  def test_telegram_administrator_status_does_not_grant_shared_conversation_controls
    @client.admin = true
    receive(group_message(1))
    receive(telegram_message(2, "/new", user: 2, chat: -10))

    assert_equal "conversation-1", @bridge.bot_detail.fetch("current").fetch("public_id")
    assert_includes reply(2), "owner"
  end

  def test_owner_bot_accepts_only_the_owners_private_chat
    @bridge.bot_audience = "owner"
    receive(telegram_message(1, "Member request", user: 2, chat: 2))
    receive(group_message(2, user: 1))
    assert_empty @bridge.inputs
    receive(telegram_message(3, "Owner request"))
    assert_equal ["speaker-1"], @bridge.inputs.values.map { |request| request.fetch(:speaker) }
  end

  def test_lost_acceptance_and_restart_keep_the_original_speaker_and_submission
    @bridge.fail_input = true
    update = group_message(1)
    assert_raises(Rho::ConnectionError) { receive(update) }
    @runtime = runtime
    receive(update)

    assert_equal 1, @bridge.inputs.length
    assert_equal "speaker-2", input(1).fetch(:speaker)
    refute input(1).key?(:tool_names)
    assert_nil @state.read["pending_update"]
  end

  def test_owner_continuation_does_not_replace_the_original_requester
    receive(group_message(1))
    receive(telegram_message(2, "/steer Owner's additional request", chat: -10, reply_to: 1, reply_user: 2))
    receive(telegram_message(3, "/steer My follow-up", user: 2, chat: -10, reply_to: 1, reply_user: 2))

    assert_equal %w[speaker-2 speaker-1 speaker-2], @bridge.inputs.values.map { |request| request.fetch(:speaker) }
    assert_equal "2", @state.read.fetch("requests").fetch("telegram:#{BOT}:#{CONNECTION}:42:1:input").fetch("owner_id")
    @bridge.inputs.each_value { |request| refute request.key?(:tool_names) }
  end

  def test_pending_media_and_following_text_keep_the_requester_after_restart
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
    @bridge.inputs.each_value do |request|
      assert_equal "speaker-2", request.fetch(:speaker)
      refute request.key?(:tool_names)
    end
    assert_empty @state.read.fetch("pending_inputs")
  end

  def test_only_requester_or_owner_can_edit_a_pending_input
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    @bridge.defer_inputs = true
    receive(group_message(1))
    @bridge.queue_rows["conversation-1"] = [{ "public_id" => "input-1", "state" => "pending", "text" => "Original" }]
    receive(telegram_message(2, "/queue", user: 2, chat: -10))
    receive(telegram_message(3, "/queue edit 1 Corrected", user: 2, chat: -10))
    assert_equal [[:edit, "conversation-1", "input-1", "Corrected", "workspace-home"]], @bridge.queue_writes
    receive(telegram_message(4, "/queue", user: 3, chat: -10))
    receive(telegram_message(5, "/queue edit 1 Someone else's change", user: 3, chat: -10))
    assert_equal 1, @bridge.queue_writes.length
    assert_includes reply(5), "sender or the bot owner"
    receive(telegram_message(6, "/queue", chat: -10))
    receive(telegram_message(7, "/queue cancel 1", chat: -10))
    assert_equal [:cancel, "conversation-1", "input-1", "workspace-home"], @bridge.queue_writes.last
  end

  def test_steering_keeps_the_frozen_execution_and_rejects_other_requesters
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    receive(group_message(1))
    receive(telegram_message(2, "/steer Change it", user: 3, chat: -10, reply_to: 1, reply_user: 2))
    assert_equal 1, @bridge.inputs.length
    assert_includes reply(2), "requester or the bot owner"
    receive(telegram_message(3, "/steer Keep reading", user: 2, chat: -10, reply_to: 1, reply_user: 2))
    assert_equal "loop-1", input(3).fetch(:expected_steering_run_public_id)
    assert_equal "steer", input(3).fetch(:mode)
    refute input(3).key?(:tool_names)
  end

  def test_only_originating_speaker_or_owner_can_answer_a_question
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    receive(group_message(1))
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "question", "kind" => "ask", "question" => "Which file?", "requester_speaker_public_id" => "speaker-2" }]
    @runtime.tick
    @now += 5
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    receive(telegram_message(2, "/answer #{question} Delete it", user: 3, chat: -10))
    assert_empty @bridge.decisions
    assert_includes reply(2), "requester or the bot owner"
    message_id = @state.read.fetch("questions").fetch(question).fetch("message_ids").first
    receive(telegram_message(3, "The requested file", user: 2, chat: -10, reply_to: message_id, reply_user: 42))
    assert_equal [["answer", "child-loop", "question", "The requested file", "workspace-home"]], @bridge.decisions
  end

  def test_an_unattributed_question_can_only_be_answered_by_the_owner
    receive(group_message(1))
    @bridge.pending_rows = [{ "workspace_public_id" => "workspace-home", "run_public_id" => "child-loop",
      "task_key" => "question", "kind" => "ask", "question" => "Which file?" }]
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    receive(telegram_message(2, "/answer #{question} A member's answer", user: 2, chat: -10))
    assert_empty @bridge.decisions
    receive(telegram_message(3, "/answer #{question} Owner's answer", chat: -10))
    assert_equal [["answer", "child-loop", "question", "Owner's answer", "workspace-home"]], @bridge.decisions
  end

  def test_local_attention_does_not_attempt_to_control_a_missing_model_task
    receive(group_message(1))
    @bridge.pending_rows = [{ "run_public_id" => nil, "task_key" => nil, "kind" => "local", "question" => "Use the CLI.",
      "requester_speaker_public_id" => "speaker-2" }]
    @runtime.tick
    question = @state.read.fetch("questions").keys.first
    receive(telegram_message(2, "/answer #{question} An answer", user: 2, chat: -10))

    assert_empty @bridge.decisions
    assert_includes reply(2), "attention in the rho CLI"
  end

  private

    def group_message(id, user: 2)
      telegram_message(id, "@rho_bot Read and summarize", user: user, chat: -10,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end

    def input(id) = @bridge.inputs.fetch("telegram:#{BOT}:#{CONNECTION}:42:#{id}:input")
    def reply(id) = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
end
