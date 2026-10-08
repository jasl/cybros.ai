require_relative "support/runtime"

class SessionWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  class SessionBridge < TelegramRuntimeSupport::Bridge
    attr_reader :conversation_reads, :attachments, :conversation_rows, :conversation_failures
    attr_accessor :fail_attach, :after_attach

    def initialize
      super
      @conversation_reads, @attachments = [], []
      @conversation_rows, @conversation_failures = {}, {}
    end

    def conversation(id, workspace_public_id: nil)
      @conversation_reads << [id, workspace_public_id]
      raise @conversation_failures[id] if @conversation_failures[id]
      unless @open_workspaces.fetch(id) == workspace_public_id
        raise Rho::Core::Refused.new("Wrong workspace", status: 404, code: "not_found")
      end

      { "public_id" => id, "title" => "Title #{id}", "workspace_public_id" => workspace_public_id }.merge(@conversation_rows.fetch(id, {}))
    end

    def attach(id, workspace_public_id:)
      @attachments << [id, workspace_public_id]
      @after_attach&.call(id)
      if @fail_attach
        @fail_attach = false
        raise Rho::ConnectionError, "attach accepted but response lost"
      end
      {}
    end
  end

  def setup
    super
    @bridge = SessionBridge.new
    @runtime = runtime
  end

  def test_empty_sessions_and_invalid_page_neither_open_nor_submit_work
    receive(telegram_message(1, "/sessions"))
    assert_includes feedback(1), "No conversations are saved in this chat/topic"
    ["0", "-1", "one", "1 2", "100000000"].each_with_index do |page, index|
      receive(telegram_message(index + 2, "/sessions #{page}"))
      assert_includes feedback(index + 2), "positive page number"
    end
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
    assert_empty @bridge.conversation_reads
  end

  def test_sessions_page_recent_roots_and_read_only_the_requested_page
    12.times { |index| receive(telegram_message(index + 1, "/new")) }
    @bridge.conversation_rows["conversation-12"] = { "title" => "  Current\nconversation  " }
    receive(telegram_message(13, "/sessions"))

    text = feedback(13)
    assert_includes text, "Sessions in this chat/topic (page 1 of 2):"
    assert_includes text, "Current conversation [current]\nconversation-12"
    assert_includes text, "\nconversation-3\n"
    refute_includes text, "\nconversation-2\n"
    assert_equal 10, @bridge.conversation_reads.length
    assert_equal ["conversation-12", "workspace-home"], @bridge.conversation_reads.first

    receive(telegram_message(14, "/sessions 2"))
    assert_includes feedback(14), "page 2 of 2"
    assert_includes feedback(14), "Title conversation-1\nconversation-1"
    assert_equal 12, @bridge.conversation_reads.length
    receive(telegram_message(15, "/sessions 3"))
    assert_includes feedback(15), "page from 1 to 2"
    assert_equal 12, @bridge.conversation_reads.length
  end

  def test_sessions_and_resume_are_scoped_to_the_exact_chat_and_topic
    sources = [{ user: 1 }, { user: 2 }, { chat: -10 }, { chat: -10, topic: 7 }, { chat: -10, topic: 8 }]
    sources.each_with_index { |source, index| receive(telegram_message(index + 1, "/new", **source)) }
    sources.each_with_index do |source, index|
      receive(telegram_message(index + 6, "/sessions", **source))
      assert_includes feedback(index + 6), "Title conversation-#{index + 1} [current]"
      foreign = (1..5).to_a - [index + 1]
      foreign.each { |other| refute_includes feedback(index + 6), "Title conversation-#{other}" }
    end
    receive(telegram_message(11, "/resume conversation-2"))
    receive(telegram_message(12, "/resume conversation-4", chat: -10, topic: 8))
    assert_includes feedback(11), "not available in this chat/topic"
    assert_includes feedback(12), "not available in this chat/topic"
    assert_empty @bridge.attachments
    assert_equal "conversation-1", saved_route.fetch("current")
    assert_equal "conversation-5", saved_route("-10:8:1").fetch("current")
  end

  def test_resume_rejects_unknown_ids_short_ids_and_another_users_group_conversation
    receive(telegram_message(1, "/new", chat: -10, topic: 7))
    receive(telegram_message(2, "/resume unknown-conversation", chat: -10, topic: 7))
    receive(telegram_message(3, "/resume conversation", chat: -10, topic: 7))
    receive(telegram_message(4, "/resume conversation-1", user: 2, chat: -10, topic: 7))
    receive(telegram_message(5, "/resume", chat: -10, topic: 7))
    assert_includes feedback(2), "not available in this chat/topic"
    assert_includes feedback(3), "not available in this chat/topic"
    assert_includes feedback(4), "not available in this chat/topic"
    assert_includes feedback(5), "exact conversation ID"
    assert_empty @bridge.attachments
    assert_empty @bridge.conversation_reads
  end

  def test_resume_restores_original_workspace_and_binding_without_changing_trackers_or_deliveries
    receive(telegram_message(1, "/new"))
    @state.change do |document|
      tracker = document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")
      tracker.merge!("position" => 7, "voice_inputs" => ["voice-input-1"])
    end
    receive(telegram_message(2, "/workspace use workspace-project"))
    @state.enqueue("old-result", route: saved_route, text: "Old work", conversation_id: "conversation-1")
    trackers = saved_route.fetch("conversations")
    old_delivery = @state.read.fetch("deliveries").fetch("old-result")
    assert_nil @state.binding("conversation-1")

    receive(telegram_message(3, "/resume conversation-1"))
    assert_includes feedback(3), "Resumed conversation conversation-1"
    assert_equal "conversation-1", saved_route.fetch("current")
    assert_equal "workspace-home", saved_route.fetch("workspace_public_id")
    assert_equal trackers, saved_route.fetch("conversations")
    assert_equal old_delivery, @state.read.fetch("deliveries").fetch("old-result")
    assert @state.binding("conversation-1")
    assert_nil @state.binding("conversation-2")
    assert_equal [["conversation-1", "workspace-home"]], @bridge.attachments
    assert_equal 2, @bridge.opened.length

    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    receive(telegram_message(4, "Continue"))
    input = @bridge.inputs.values.last
    assert_equal "conversation-1", input.fetch(:conversation_id)
    assert_equal "workspace-home", input.fetch(:workspace_public_id)
    assert_equal 7, saved_route.fetch("conversations").fetch("conversation-1").fetch("position")
  end

  def test_resuming_discards_only_this_routes_pending_inputs_and_voice
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    @state.change do |document|
      document.fetch("pending_inputs")["own"] = { "route_key" => "1:0", "batch_key" => "own" }
      document.fetch("pending_inputs")["other"] = { "route_key" => "2:0", "batch_key" => "other" }
      document.fetch("deliveries")["voice:own"] = {
        "voice" => true, "status" => "pending", "chat_id" => "1", "topic_id" => nil, "route_key" => "1:0",
      }
      document.fetch("deliveries")["voice:other"] = {
        "voice" => true, "status" => "pending", "chat_id" => "2", "topic_id" => nil, "route_key" => "2:0",
      }
    end
    receive(telegram_message(3, "/resume conversation-1"))
    assert_equal ["other"], @state.read.fetch("pending_inputs").keys
    refute @state.read.fetch("deliveries").key?("voice:own")
    assert @state.read.fetch("deliveries").key?("voice:other")
  end

  def test_archived_and_unreadable_targets_leave_the_selection_and_pending_inputs_alone
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    @state.change { |document| document.fetch("pending_inputs")["own"] = { "route_key" => "1:0" } }
    @bridge.conversation_rows["conversation-1"] = { "archived_at" => "2026-09-30T00:00:00Z" }
    receive(telegram_message(3, "/resume conversation-1"))
    assert_includes feedback(3), "archived"
    receive(telegram_message(4, "/sessions"))
    assert_includes feedback(4), "Title conversation-1 [archived]"
    [403, 404].each_with_index do |status, index|
      @bridge.conversation_failures["conversation-1"] = Rho::Core::Refused.new("Source unreadable", status: status, code: "not_authorized")
      receive(telegram_message(index + 5, "/resume conversation-1"))
      assert_includes feedback(index + 5), "no longer readable"
    end
    assert_equal "conversation-2", saved_route.fetch("current")
    assert_equal ["own"], @state.read.fetch("pending_inputs").keys
    assert_empty @bridge.attachments
  end

  def test_sessions_show_unavailable_without_any_cached_title
    receive(telegram_message(1, "/new"))
    @bridge.conversation_rows["conversation-1"] = { "title" => "Previously visible private title" }
    receive(telegram_message(2, "/sessions"))
    assert_includes feedback(2), "Previously visible private title"
    @bridge.conversation_failures["conversation-1"] = Rho::Core::Refused.new("Source unreadable", status: 404, code: "not_found")
    receive(telegram_message(3, "/sessions"))
    assert_includes feedback(3), "Unavailable [current]\nconversation-1"
    refute_includes feedback(3), "Previously visible"
  end

  def test_lost_attach_response_retries_the_same_source_and_workspace_after_restart
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/workspace use workspace-project"))
    update = telegram_message(3, "/resume conversation-1")
    @bridge.fail_attach = true
    assert_raises(Rho::ConnectionError) { receive(update) }
    assert_equal "conversation-2", saved_route.fetch("current")
    assert_nil @state.read.fetch("pending_update")["control_status"]
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    receive(update)
    assert_equal "conversation-1", saved_route.fetch("current")
    assert_equal "workspace-home", saved_route.fetch("workspace_public_id")
    assert_equal [["conversation-1", "workspace-home"], ["conversation-1", "workspace-home"]], @bridge.attachments
    assert_equal 4, @state.read.fetch("offset")
    assert_nil @state.read["pending_update"]
  end

  def test_saved_resume_result_is_acknowledged_after_restart_without_reapplying_the_selection
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    update = telegram_message(3, "/resume conversation-1")
    @runtime.define_singleton_method(:reply) { |*| raise Rho::ConnectionError, "Local reply interrupted" }
    assert_raises(Rho::ConnectionError) { receive(update) }
    assert_equal "conversation-1", saved_route.fetch("current")
    assert_equal "applied", @state.read.fetch("pending_update").fetch("control_status")
    @state.change { |document| document.fetch("routes").fetch("1:0")["current"] = "conversation-2" }
    @runtime = runtime
    receive(update)
    assert_equal "conversation-2", saved_route.fetch("current")
    assert_includes feedback(3), "Resumed conversation conversation-1"
    assert_equal 1, @bridge.attachments.length
  end

  def test_duplicate_completed_resume_after_new_does_not_reselect_old_conversation
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    update = telegram_message(3, "/resume conversation-1")
    receive(update)
    receive(telegram_message(4, "/new"))
    @runtime = runtime
    receive(update)
    assert_equal "conversation-3", saved_route.fetch("current")
    assert_equal 1, @bridge.attachments.length
  end

  def test_target_retired_while_attaching_is_not_recreated_or_selected
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    @bridge.after_attach = ->(id) { @runtime.send(:retire_source, id) }
    receive(telegram_message(3, "/resume conversation-1"))
    assert_equal "conversation-2", saved_route.fetch("current")
    refute saved_route.fetch("conversations").key?("conversation-1")
    assert_includes feedback(3), "no longer available in this chat/topic"
  end

  def test_old_work_keeps_its_destination_and_cursor_after_resume_and_restart
    receive(telegram_message(1, "/new", chat: -10, topic: 7))
    receive(telegram_message(2, "/new", chat: -10, topic: 7))
    receive(telegram_message(3, "/new", chat: -10, topic: 8))
    @state.change do |document|
      document.fetch("routes").fetch("-10:7:1").fetch("conversations").fetch("conversation-2")["position"] = 1
      document.fetch("deliveries").clear
    end
    @bridge.turn_rows["conversation-2"] = [turn(1, "Already delivered", conversation_id: "conversation-2"),
      turn(2, "Late original topic answer", conversation_id: "conversation-2")]
    receive(telegram_message(4, "/resume conversation-1", chat: -10, topic: 7))
    @state.change { |document| document.fetch("deliveries").clear }
    @runtime = runtime
    3.times do
      @now += 6
      @runtime.tick
    end
    sent = @client.calls.select { |method, params| method == "sendMessage" && params[:text]&.include?("Late original topic answer") }
    assert_equal 1, sent.length
    assert_equal "-10", sent.first.last.fetch(:chat_id)
    assert_equal 7, sent.first.last.fetch(:message_thread_id)
    refute @client.calls.any? { |_method, params| params[:text]&.include?("Already delivered") }
    assert_equal 2, saved_route("-10:7:1").fetch("conversations").fetch("conversation-2").fetch("position")
    assert_equal "conversation-1", saved_route("-10:7:1").fetch("current")
    assert_equal "conversation-3", saved_route("-10:8:1").fetch("current")
  end

  private

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
    def saved_route(key = "1:0") = @state.read.fetch("routes").fetch(key)
end
