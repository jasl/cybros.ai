require_relative "support/runtime"

class SessionWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  class SessionBridge < TelegramRuntimeSupport::Bridge
    attr_reader :conversation_reads, :history_reads, :resume_calls, :conversation_rows, :conversation_failures
    attr_accessor :fail_resume, :before_resume

    def initialize
      super
      @conversation_reads, @history_reads, @resume_calls = [], [], []
      @conversation_rows, @conversation_failures = {}, {}
    end

    def conversation(id, workspace_public_id: nil)
      @conversation_reads << [id, workspace_public_id]
      raise @conversation_failures[id] if @conversation_failures[id]
      unless @open_workspaces.fetch(id) == workspace_public_id
        raise Rho::Core::Refused.new("Wrong workspace", status: 404, code: "not_found")
      end

      projection(id)
    end

    def bot_history(after: nil, limit: 10, archived: nil)
      @history_reads << [after, limit, archived]
      rows = @opened.values.reverse.reject { |id| @conversation_failures.key?(id) }.map { |id| projection(id) }
      rows.select! { |row| !!row["archived_at"] == archived } unless archived.nil?
      rows = rows.drop(after.to_i)
      { "conversations" => rows.take(limit), "pagination" => { "next_after" => ((after.to_i + limit).to_s if rows.length > limit) } }
    end

    def resume_bot_conversation(operation_id:, conversation_public_id:, workspace_public_id:)
      @resume_calls << [operation_id, conversation_public_id, workspace_public_id]
      @before_resume&.call(conversation_public_id)
      conversation(conversation_public_id, workspace_public_id: workspace_public_id)
      result = super
      if @fail_resume
        @fail_resume = false
        raise Rho::ConnectionError, "resume accepted but response lost"
      end
      result
    end

    private

      def projection(id)
        { "public_id" => id, "title" => "Title #{id}", "workspace_public_id" => @open_workspaces.fetch(id),
          "archived_at" => ("2026-10-12" if @archived_conversations.include?(id)) }.merge(@conversation_rows.fetch(id, {}))
      end
  end

  def setup
    super
    @bridge = SessionBridge.new
    @runtime = runtime
  end

  def test_empty_sessions_and_invalid_page_neither_open_nor_submit_work
    receive(telegram_message(1, "/sessions"))
    assert_includes feedback(1), "No conversations are saved for this Bot"
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
    assert_includes text, "Bot conversations (page 1):"
    assert_includes text, "Current conversation [current]\nconversation-12"
    assert_includes text, "\nconversation-3\n"
    refute_includes text, "\nconversation-2\n"
    assert_includes text, "Next page: /sessions 2"
    assert_equal [[nil, 10, nil]], @bridge.history_reads
    assert_empty @bridge.conversation_reads
    assert_equal 10, saved_route.fetch("session_locators").length

    receive(telegram_message(14, "/sessions 2"))
    assert_includes feedback(14), "page 2"
    assert_includes feedback(14), "Title conversation-1 [archived]\nconversation-1"
    refute_includes feedback(14), "Next page"
    assert_equal [[nil, 10, nil], ["10", 10, nil]], @bridge.history_reads
    assert_equal 2, saved_route.fetch("session_locators").length
    receive(telegram_message(15, "/sessions 3"))
    assert_includes feedback(15), "page has not been listed yet"
    assert_equal 2, @bridge.history_reads.length
  end

  def test_admitted_group_members_share_current_and_history_but_only_the_owner_can_resume
    receive(telegram_message(1, "/new", chat: -10, topic: 4))
    receive(telegram_message(2, "/new", chat: -10, topic: 4))
    [1, 2].each_with_index do |user, index|
      receive(telegram_message(index + 3, "/sessions", chat: -10, topic: 4, user: user))
      assert_includes feedback(index + 3), "Title conversation-2 [current]"
      assert_includes feedback(index + 3), "Title conversation-1 [archived]"
    end
    receive(telegram_message(5, "/resume conversation-1", chat: -10, topic: 4, user: 2))
    assert_includes feedback(5), "Only the bot owner"
    assert_empty @bridge.resume_calls
    assert_equal "conversation-2", current.fetch("public_id")
    receive(telegram_message(6, "/resume conversation-1", chat: -10, topic: 4))
    assert_equal "conversation-1", current.fetch("public_id")
    assert_equal 2, @bridge.opened.length
  end

  def test_resume_requires_an_exact_known_id_and_owner_authority
    receive(telegram_message(1, "/new", chat: -10, topic: 7))
    receive(telegram_message(2, "/resume unknown-conversation", chat: -10, topic: 7))
    receive(telegram_message(3, "/resume conversation", chat: -10, topic: 7))
    receive(telegram_message(4, "/resume conversation-1", user: 2, chat: -10, topic: 7))
    receive(telegram_message(5, "/resume", chat: -10, topic: 7))
    assert_includes feedback(2), "Use /sessions to list"
    assert_includes feedback(3), "Use /sessions to list"
    assert_includes feedback(4), "Only the bot owner"
    assert_includes feedback(5), "exact conversation ID"
    assert_empty @bridge.resume_calls
    assert_empty @bridge.conversation_reads
  end

  def test_resume_restores_original_workspace_and_binding_without_changing_trackers_or_deliveries
    receive(telegram_message(1, "/new"))
    @state.change do |document|
      tracker = document.fetch("routes").fetch("#{CONNECTION}:1:0").fetch("conversations").fetch("conversation-1")
      tracker.merge!("position" => 7, "voice_inputs" => ["voice-input-1"])
    end
    receive(telegram_message(2, "/workspace use workspace-project"))
    @state.enqueue("old-result", route: saved_route, text: "Old work", conversation_id: "conversation-1")
    trackers = saved_route.fetch("conversations")
    old_delivery = @state.read.fetch("deliveries").fetch("old-result")
    assert @state.binding("conversation-1"), "historical conversations retain their ingress binding"

    receive(telegram_message(3, "/resume conversation-1"))
    assert_includes feedback(3), "Resumed conversation conversation-1"
    assert_equal({ "public_id" => "conversation-1", "workspace_public_id" => "workspace-home" }, current)
    assert_equal trackers, saved_route.fetch("conversations")
    assert_equal old_delivery, @state.read.fetch("deliveries").fetch("old-result")
    assert @state.binding("conversation-1")
    assert @state.binding("conversation-2")
    assert_equal [["telegram:#{BOT}:#{CONNECTION}:42:3:resume", "conversation-1", "workspace-home"]], @bridge.resume_calls
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
      document.fetch("pending_inputs")["own"] = { "route_key" => "#{CONNECTION}:1:0", "batch_key" => "own" }
      document.fetch("pending_inputs")["other"] = { "route_key" => "#{CONNECTION}:2:0", "batch_key" => "other" }
      document.fetch("deliveries")["voice:own"] = {
        "voice" => true, "status" => "pending", "chat_id" => "1", "topic_id" => nil, "route_key" => "#{CONNECTION}:1:0",
      }
      document.fetch("deliveries")["voice:other"] = {
        "voice" => true, "status" => "pending", "chat_id" => "2", "topic_id" => nil, "route_key" => "#{CONNECTION}:2:0",
      }
    end
    receive(telegram_message(3, "/resume conversation-1"))
    assert_equal ["other"], @state.read.fetch("pending_inputs").keys
    refute @state.read.fetch("deliveries").key?("voice:own")
    assert @state.read.fetch("deliveries").key?("voice:other")
  end

  def test_archived_history_can_be_resumed_and_the_replaced_current_is_archived
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    receive(telegram_message(3, "/sessions"))
    assert_includes feedback(3), "Title conversation-1 [archived]"
    receive(telegram_message(4, "/resume conversation-1"))
    assert_equal "conversation-1", current.fetch("public_id")
    receive(telegram_message(5, "/sessions"))
    assert_includes feedback(5), "Title conversation-1 [current]"
    assert_includes feedback(5), "Title conversation-2 [archived]"
    assert_empty @bridge.stops
  end

  def test_unreadable_targets_leave_the_selection_and_pending_inputs_alone
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    @state.change { |document| document.fetch("pending_inputs")["own"] = { "route_key" => "#{CONNECTION}:1:0", "batch_key" => "own" } }
    [403, 404].each_with_index do |status, index|
      @bridge.conversation_failures["conversation-1"] = Rho::Core::Refused.new("Source unreadable", status: status, code: "not_authorized")
      receive(telegram_message(index + 3, "/resume conversation-1"))
      assert_includes feedback(index + 3), "cannot be resumed for this Bot"
    end
    assert_equal "conversation-2", current.fetch("public_id")
    assert_equal ["own"], @state.read.fetch("pending_inputs").keys
  end

  def test_sessions_do_not_reuse_cached_titles_when_history_loses_read_access
    receive(telegram_message(1, "/new"))
    @bridge.conversation_rows["conversation-1"] = { "title" => "Previously visible private title" }
    receive(telegram_message(2, "/sessions"))
    assert_includes feedback(2), "Previously visible private title"
    @bridge.conversation_failures["conversation-1"] = Rho::Core::Refused.new("Source unreadable", status: 404, code: "not_found")
    receive(telegram_message(3, "/sessions"))
    assert_includes feedback(3), "No conversations are saved for this Bot"
    refute_includes feedback(3), "Previously visible"
  end

  def test_lost_resume_response_retries_the_same_operation_and_workspace_after_restart
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/workspace use workspace-project"))
    update = telegram_message(3, "/resume conversation-1")
    @bridge.fail_resume = true
    assert_raises(Rho::ConnectionError) { receive(update) }
    assert_equal "conversation-1", current.fetch("public_id"), "Core accepted the switch before its response was lost"
    assert_nil @state.read.fetch("pending_update")["control_status"]
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    receive(update)
    assert_equal({ "public_id" => "conversation-1", "workspace_public_id" => "workspace-home" }, current)
    assert_equal [["telegram:#{BOT}:#{CONNECTION}:42:3:resume", "conversation-1", "workspace-home"]] * 2, @bridge.resume_calls
    assert_equal 4, @connection_state.read.fetch("offset")
    assert_nil @state.read["pending_update"]
  end

  def test_saved_resume_result_is_acknowledged_after_restart_without_reapplying_the_selection
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    update = telegram_message(3, "/resume conversation-1")
    @runtime.define_singleton_method(:reply) { |*| raise Rho::ConnectionError, "Local reply interrupted" }
    assert_raises(Rho::ConnectionError) { receive(update) }
    assert_equal "conversation-1", current.fetch("public_id")
    assert_equal "applied", @state.read.fetch("pending_update").fetch("control_status")
    @bridge.resume_bot_conversation(operation_id: "webui-switch", conversation_public_id: "conversation-2", workspace_public_id: "workspace-home")
    @runtime = runtime
    receive(update)
    assert_equal "conversation-2", current.fetch("public_id")
    assert_includes feedback(3), "Resumed conversation conversation-1"
    assert_equal 1, @bridge.resume_calls.count { |operation,| operation.end_with?(":3:resume") }
  end

  def test_duplicate_completed_resume_after_new_does_not_reselect_old_conversation
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    update = telegram_message(3, "/resume conversation-1")
    receive(update)
    receive(telegram_message(4, "/new"))
    @runtime = runtime
    receive(update)
    assert_equal "conversation-3", current.fetch("public_id")
    assert_equal 1, @bridge.resume_calls.length
  end

  def test_target_retired_before_core_switch_is_not_recreated_or_selected
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/new"))
    @bridge.before_resume = lambda do |id|
      @runtime.send(:retire_source, id)
      @bridge.conversation_failures[id] = Rho::Core::Refused.new("Source unreadable", status: 404, code: "not_found")
    end
    receive(telegram_message(3, "/resume conversation-1"))
    assert_equal "conversation-2", current.fetch("public_id")
    refute saved_route.fetch("conversations").key?("conversation-1")
    assert_includes feedback(3), "cannot be resumed for this Bot"
  end

  def test_sessions_restore_the_original_workspace_after_home_changes_and_adapter_trackers_are_lost
    receive(telegram_message(1, "/new"))
    receive(telegram_message(2, "/workspace use workspace-project"))
    @state.change { |document| document.fetch("routes").clear }
    @runtime = runtime
    receive(telegram_message(3, "/sessions"))
    assert_includes feedback(3), "conversation-1"
    assert_equal "workspace-home", saved_route.fetch("session_locators").fetch("conversation-1")
    refute saved_route.fetch("conversations").key?("conversation-1")
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    receive(telegram_message(4, "/resume conversation-1"))

    assert_equal({ "public_id" => "conversation-1", "workspace_public_id" => "workspace-home" }, current)
    assert_equal ["conversation-1", "workspace-home"], @bridge.conversation_reads.last
    assert_equal "workspace-project", @bridge.bot_detail.fetch("bot").fetch("home_workspace_public_id")
    assert_empty @bridge.inputs
    assert_empty @bridge.stops
  end

  def test_old_work_keeps_its_destination_and_cursor_after_resume_and_restart
    receive(telegram_message(1, "/new", chat: -10, topic: 7))
    receive(telegram_message(2, "/new", chat: -10, topic: 7))
    @bridge.new_bot_conversation(operation_id: "webui-new")
    @state.change do |document|
      document.fetch("routes").fetch("#{CONNECTION}:-10:7").fetch("conversations").fetch("conversation-2")["position"] = 1
      document.fetch("deliveries").clear
    end
    @bridge.turn_rows["conversation-2"] = [turn(1, "Already delivered", conversation_id: "conversation-2"),
      turn(2, "Late original topic answer", conversation_id: "conversation-2")]
    receive(telegram_message(3, "/resume conversation-1", chat: -10, topic: 7))
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
    assert_equal 2, saved_route("#{CONNECTION}:-10:7").fetch("conversations").fetch("conversation-2").fetch("position")
    assert_equal "conversation-1", current.fetch("public_id")
    assert_empty @bridge.stops
  end

  private

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
    def saved_route(key = "#{CONNECTION}:1:0") = @state.read.fetch("routes").fetch(key)
    def current = @bridge.bot_detail.fetch("current")
end
