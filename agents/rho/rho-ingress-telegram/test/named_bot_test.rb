require "support/runtime"
require "support/schedules"

class TelegramNamedBotTest < Minitest::Test
  include TelegramRuntimeSupport

  BOT_ID = "019a0000-0000-7000-8000-000000000001"

  def setup
    super
    @bridge.bot_audience = "owner"
    @runtime = named_runtime
  end

  def test_named_inputs_and_schedules_leave_model_choice_with_the_bot
    @bridge.extend(TelegramScheduleSupport)
    @bridge.prepare_schedules
    receive(telegram_message(1, "hello"))
    assert_nil @bridge.inputs.values.last.fetch(:model)
    @runtime.configure(settings: @settings, default_model: "vendor/changed-rho-default")
    receive(telegram_message(2, "/job create once in 30m inspect the report"))
    assert_nil @bridge.job_rows.values.last["model"]
    receive(telegram_message(3, "/model vendor/model"))
    receive(telegram_message(4, "explicit selection"))
    assert_equal "vendor/model", @bridge.inputs.values.last.fetch(:model)
  end

  def test_named_connection_rejects_other_users_and_groups_before_media_or_core_work
    consume(telegram_message(1, "ignored", user: 2))
    consume(telegram_message(2, "@rho_bot hello", user: 1, chat: -10))
    media = telegram_message(3, nil, user: 2)
    media.fetch("message")["photo"] = [{ "file_id" => "private-photo", "width" => 10, "height" => 10 }]
    consume(media)
    consume(telegram_message(4, "/start", user: 2))
    @runtime.tick
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.speakers
    assert_empty @state.read.fetch("pending_inputs")
    assert_empty @state.read.fetch("routes")
    assert_equal 5, @connection_state.read.fetch("offset")
    assert_empty @client.calls.select { |method, _params| method == "getFile" }
    replies = @client.calls.select { |method, _params| method == "sendMessage" }
    assert_equal 1, replies.length
    assert_includes replies.first.last.fetch(:text), "2"
    assert_includes replies.first.last.fetch(:text), "owner"
  end

  def test_home_setting_change_creates_a_new_current_while_running_work_keeps_its_workspace
    receive(telegram_message(1, "first"))
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = named_runtime
    receive(telegram_message(2, "same conversation"))
    assert_equal "workspace-home", @bridge.inputs.values.last.fetch(:workspace_public_id)
    receive(telegram_message(3, "/workspace use workspace-project"))
    assert_equal 2, @bridge.opened.length
    receive(telegram_message(4, "new conversation"))
    assert_equal "workspace-project", @bridge.inputs.values.last.fetch(:workspace_public_id)
    assert_equal ["workspace-home", "workspace-project"], @bridge.open_workspaces.values
    assert @bridge.opened.keys.all? { |key| key.start_with?("telegram:#{BOT_ID}:#{CONNECTION}:42:") }
    assert_equal "workspace-home", @state.read.fetch("routes").fetch("#{CONNECTION}:1:0").fetch("conversations").fetch("conversation-1").fetch("workspace_public_id")
  end

  def test_lost_create_response_keeps_the_original_home_after_restart
    @bridge.fail_open = true
    update = telegram_message(1, "first")
    assert_raises(Rho::ConnectionError) { receive(update) }
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = named_runtime
    receive(update)
    assert_equal 1, @bridge.opened.length
    assert_equal "workspace-home", @bridge.inputs.values.last.fetch(:workspace_public_id)
  end

  def test_audience_enables_existing_access_live_and_retains_shared_history_with_distinct_speakers
    receive(telegram_message(1, "owner only", user: 2))
    assert_empty @bridge.inputs
    @bridge.bot_audience = "external"
    receive(telegram_message(2, "first person's request", user: 2))
    receive(telegram_message(3, "owner request"))
    assert_equal 1, @bridge.opened.length
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |request| request.fetch(:conversation_id) }.uniq
    assert_equal %w[speaker-2 speaker-1], @bridge.inputs.values.map { |request| request.fetch(:speaker) }
    assert_nil @bridge.inputs.values.first[:tool_names]
    receive(telegram_message(4, "@rho_bot group request", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    assert_equal 1, @bridge.opened.length
    receive(telegram_message(5, "/sessions", user: 2))
    text = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT_ID}:#{CONNECTION}:42:5:reply").fetch("text")
    assert_includes text, "conversation-1"
    refute_includes text, "conversation-2"
    refute_includes text, "conversation-3"
  end

  def test_external_admission_requires_both_user_and_group_and_keeps_owner_controls
    @bridge.bot_audience = "external"
    receive(telegram_message(1, "@rho_bot unauthorized user", user: 3, chat: -10))
    receive(telegram_message(2, "@rho_bot unauthorized group", user: 2, chat: -20))
    assert_empty @bridge.opened
    receive(telegram_message(3, "/access users add 3", user: 2))
    refute_includes @state.read.fetch("access").fetch("allowed_users"), "3"
    receive(telegram_message(4, "/access users add 3"))
    assert_includes @state.read.fetch("access").fetch("allowed_users"), "3"
    receive(telegram_message(5, "now permitted", user: 3))
    assert_equal 1, @bridge.opened.length
    receive(telegram_message(6, "/ignore add 3"))
    receive(telegram_message(7, "ignored", user: 3))
    assert_equal 1, @bridge.inputs.length
  end

  def test_external_inputs_use_each_visitors_speaker_without_adapter_memory_overrides
    @bridge.bot_audience = "external"
    receive(telegram_message(1, "Owner visit"))
    receive(telegram_message(2, "Another person", user: 2))
    receive(telegram_message(3, "@rho_bot Group visit", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    assert_equal %w[speaker-1 speaker-2 speaker-2], @bridge.inputs.values.map { |request| request.fetch(:speaker) }
    assert_equal ["conversation-1"], @bridge.inputs.values.map { |request| request.fetch(:conversation_id) }.uniq
    @bridge.inputs.each_value do |request|
      refute request.key?(:memory_context)
      refute request.key?(:tool_names)
    end
    assert_empty @bridge.memory_anchors
    assert @bridge.memory_bindings.values.all?(&:nil?)
  end

  private

    def named_runtime
      Rho::IngressTelegram::Runtime.new(settings: @settings, state: @state, bridge: @bridge,
        client: @client, log: nil, clock: -> { @now }, default_model: "vendor/rho-default", agent_public_id: BOT_ID)
        .tap { |runtime| runtime.identify("id" => 42, "username" => "rho_bot") }
    end
end
