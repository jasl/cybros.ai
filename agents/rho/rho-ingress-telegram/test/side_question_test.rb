require "support/runtime"

class TelegramSideQuestionTest < Minitest::Test
  include TelegramRuntimeSupport

  class SideBridge < TelegramRuntimeSupport::Bridge
    attr_reader :sides, :side_opens, :memory_binding_calls

    def initialize
      super
      @sides, @side_opens = {}, []
      @memory_binding_calls = []
    end

    def open_side(parent:)
      @side_opens << parent
      @sides[parent] ||= "side-#{@sides.length + 1}"
    end

    def bind_memory(id, memory_context:, workspace_public_id:)
      @memory_binding_calls << [id, memory_context, workspace_public_id]
      super
    end
  end

  def setup
    super
    @bridge = SideBridge.new
    @runtime = runtime
  end

  def test_side_answer_is_followed_in_the_original_topic_without_switching_the_main_conversation
    @runtime.consume(telegram_message(1, "/btw Explain that term", chat: -10, topic: 7))
    route = @state.read.fetch("routes").fetch("-10:7:1")
    assert_equal "conversation-1", route.fetch("current")
    assert_equal "conversation-1", route.fetch("conversations").fetch("side-1").fetch("side_parent")
    input = @bridge.inputs.fetch("telegram:42:1:side-input")
    assert_equal "side-1", input.fetch(:conversation_id)
    assert_equal "Explain that term", input.fetch(:text)
    assert_equal "speaker-1", input.fetch(:speaker)
    assert_equal "workspace-home", input.fetch(:workspace_public_id)
    assert_empty @bridge.stops

    @bridge.turn_rows["side-1"] = [turn(0, "A quick explanation", conversation_id: "side-1")]
    @runtime.tick
    delivery = @state.read.fetch("deliveries").fetch("turn:side-1:side-1-turn-0:side-1-variant-0")
    assert_equal "Side answer:\nA quick explanation", delivery.fetch("text")
    assert_equal "-10", delivery.fetch("chat_id")
    assert_equal 7, delivery.fetch("topic_id")
    @now += 4
    @runtime.tick
    formal = @client.calls.select { |method, params| method == "sendMessage" && params[:text].start_with?("Side answer:") }
    assert_equal 1, formal.length
    assert_equal 7, formal.first.last.fetch(:message_thread_id)
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("-10:7:1").fetch("current")
  end

  def test_lost_input_reply_reuses_the_saved_side_and_frozen_model_after_restart
    @runtime.consume(telegram_message(1, "Start"))
    @state.change { |doc| doc.fetch("routes").fetch("1:0")["model"] = "vendor/original" }
    update = telegram_message(2, "/btw Explain this")
    @bridge.fail_input = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @bridge.default_workspace = @bridge.workspace_rows.last
    @state.change { |doc| doc.fetch("routes").fetch("1:0")["model"] = "vendor/new" }
    assert_equal "side-1", @state.read.fetch("pending_update").fetch("side_conversation_id")

    @runtime = runtime
    @runtime.consume(update)
    @runtime.consume(update)

    assert_equal ["conversation-1"], @bridge.side_opens
    assert_equal 2, @bridge.inputs.length
    accepted = @bridge.inputs.fetch("telegram:42:2:side-input")
    assert_equal "side-1", accepted.fetch(:conversation_id)
    assert_equal "vendor/original", accepted.fetch(:model)
    assert_equal "workspace-home", accepted.fetch(:workspace_public_id)
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  def test_reused_legacy_nonowner_private_side_gets_person_memory_before_its_next_input
    @runtime.consume(telegram_message(1, "/btw First question", user: 2))
    context = @bridge.memory_bindings.fetch("side-1")
    restart_with_legacy_side("2:0")

    @runtime.consume(telegram_message(2, "/btw Continue that question", user: 2))

    assert_equal context, @bridge.memory_bindings.fetch("side-1")
    assert_equal %w[conversation person], context.fetch("bindings").map { |row| row.fetch("name") }
    assert_equal %w[conversation conversation], context.fetch("bindings").map { |row| row.fetch("scope") }
    input = @bridge.inputs.fetch("telegram:42:2:side-input")
    assert_equal "side-1", input.fetch(:conversation_id)
    assert_equal true, input.fetch(:isolated)
    assert_equal true, input.fetch(:side)
    assert_empty input.fetch(:tool_names)
    assert_equal ["conversation-1", "conversation-1"], @bridge.side_opens
  end

  def test_reused_legacy_nonowner_group_side_gets_read_only_shared_memory_after_restart
    @runtime.consume(telegram_message(1, "/btw First question", user: 2, chat: -10, topic: 7))
    context = @bridge.memory_bindings.fetch("side-1")
    restart_with_legacy_side("-10:7:2")

    @runtime.consume(telegram_message(2, "/btw Continue that question", user: 2, chat: -10, topic: 7))

    assert_equal context, @bridge.memory_bindings.fetch("side-1")
    assert_equal %w[conversation group], context.fetch("bindings").map { |row| row.fetch("name") }
    assert_equal "read", context.fetch("bindings").last.fetch("access")
    assert_equal context, @bridge.memory_bindings.fetch("conversation-1")
    input = @bridge.inputs.fetch("telegram:42:2:side-input")
    assert_equal "side-1", input.fetch(:conversation_id)
    assert_equal true, input.fetch(:isolated)
    assert_equal true, input.fetch(:side)
    assert_empty input.fetch(:tool_names)
  end

  def test_new_nonowner_side_acceptance_retry_keeps_its_memory_binding_without_reopening
    @bridge.fail_input = true
    update = telegram_message(1, "/btw First question", user: 2)
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    context = @bridge.memory_bindings.fetch("side-1")
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime

    @runtime.consume(update)
    @runtime.consume(update)

    assert_equal context, @bridge.memory_bindings.fetch("side-1")
    assert_equal %w[conversation person], context.fetch("bindings").map { |row| row.fetch("name") }
    assert_equal [["side-1", context, "workspace-home"]], @bridge.memory_binding_calls
    assert_equal ["conversation-1"], @bridge.side_opens
    assert_equal 1, @bridge.inputs.length
    assert_equal 1, @bridge.memory_anchors.length
    assert_equal true, @state.read.fetch("routes").dig("2:0", "conversations", "side-1", "memory_bound")
  end

  def test_empty_side_question_never_creates_a_conversation
    @runtime.consume(telegram_message(1, "/btw "))

    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_includes @state.read.fetch("deliveries").fetch("control:1").fetch("text"), "/btw"
  end

  def test_inherited_history_advances_the_cursor_without_resending_parent_answers
    @runtime.consume(telegram_message(1, "/btw Explain this"))
    @bridge.turn_rows["side-1"] = [turn(0, "Parent answer", conversation_id: "side-1").merge("inherited" => true)]
    @runtime.tick

    assert_equal 0, @state.read.fetch("routes").dig("1:0", "conversations", "side-1", "position")
    refute @state.read.fetch("deliveries").key?("turn:side-1:side-1-turn-0:side-1-variant-0")
    @bridge.turn_rows["side-1"] << turn(1, "Side answer only", conversation_id: "side-1")
    @now += Rho::IngressTelegram::Runtime::RECONCILE_INTERVAL
    @runtime.tick
    assert_equal 1, @state.read.fetch("routes").dig("1:0", "conversations", "side-1", "position")
    refute @client.calls.any? { |_method, params| params[:text].to_s.include?("Parent answer") }
    assert @client.calls.any? { |_method, params| params[:text].to_s.include?("Side answer only") }
  end

  def test_stop_targets_the_replied_side_task_without_stopping_parent_or_previous_work
    @runtime.consume(telegram_message(1, "/btw Old side"))
    @runtime.consume(telegram_message(2, "/new"))
    @runtime.consume(telegram_message(3, "/btw Current side"))
    @runtime.consume(telegram_message(4, "/stop", reply_to: 3, reply_user: 1))

    assert_equal [["loop-2", "agent_loop", "workspace-home"]], @bridge.stop_calls
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  def test_current_side_is_bound_for_webui_and_new_releases_the_previous_binding
    @runtime.consume(telegram_message(1, "/btw Explain this"))
    assert_equal "telegram", @state.binding("side-1").fetch("channel")

    @runtime.consume(telegram_message(2, "/new"))

    assert_nil @state.binding("side-1")
    assert_nil @state.binding("conversation-1")
    assert_equal "telegram", @state.binding("conversation-2").fetch("channel")
  end

  def test_an_ambiguous_side_stop_is_not_repeated_or_redirected_after_restart
    @runtime.consume(telegram_message(1, "/btw Explain this"))
    @bridge.fail_stop = true
    update = telegram_message(2, "/stop", reply_to: 1, reply_user: 1)
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    assert_equal [["loop-1", "agent_loop", "workspace-home"]], @bridge.stop_calls

    @runtime = runtime
    @runtime.consume(update)

    assert_equal [["loop-1", "agent_loop", "workspace-home"]], @bridge.stop_calls
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "was not repeated"
    assert_nil @state.read["pending_update"]
  end

  private

    def restart_with_legacy_side(route_key)
      @state.change do |document|
        document.fetch("routes").fetch(route_key).fetch("conversations").each_value { |row| row.delete("memory_bound") }
      end
      @bridge.memory_bindings.clear
      @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
      @runtime = runtime
    end
end
