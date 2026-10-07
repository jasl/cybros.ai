require "support/runtime"

class ConversationWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  INPUT_ID = "01900000-0000-7000-8000-000000000001"
  VARIANT_ID = "01900000-0000-7000-8000-000000000002"

  class HistoryBridge < TelegramRuntimeSupport::Bridge
    attr_reader :history_calls, :operations, :forks, :attaches, :decks, :regeneration_keys
    attr_accessor :search_pages, :fail_fork, :fail_regenerate, :fail_control, :history_rows, :transcript_page

    def initialize
      super
      @history_calls, @operations, @attaches, @forks, @decks = [], [], [], {}, {}
      @search_pages, @history_rows = {}, {}
      @regeneration_keys = []
    end

    def submit(id, **fields)
      result = super
      result["input"]["public_id"] = INPUT_ID
      result
    end

    def history(id, before_position: nil, workspace_public_id:)
      @history_calls << [id, before_position, workspace_public_id]
      { "turns" => @history_rows.fetch(id, []),
        "pagination" => { "before_position" => 3, "has_older" => before_position.nil? } }
    end

    def search_conversations(query:, after: nil, workspace_public_id:)
      @history_calls << [query, after, workspace_public_id]
      @search_pages.fetch([workspace_public_id, after], { "matches" => [], "pagination" => { "next_after" => nil } })
    end

    def history_turn(id, reference: nil, workspace_public_id:)
      row = reference ? @turn_rows.fetch(id, []).find { |turn| turn.fetch("position").to_s == reference } : @turn_rows.fetch(id, []).last
      row&.slice("public_id", "position", "answering_user_public_id")&.merge("active_variant" => {
        "public_id" => row.fetch("variant_public_id"), "run_public_id" => row.fetch("run_public_id", "loop-1"),
        "memory_context" => row["memory_context"],
      })
    end

    def isolated_history_turn?(turn)
      turn["answering_user_public_id"] == "group-profile" && !turn.dig("active_variant", "memory_context").nil?
    end

    def rename_conversation(id, title:, workspace_public_id:)
      @operations << ["rename", id, title, workspace_public_id]
      fail_response
    end

    def archive_conversation(id, workspace_public_id:)
      @operations << ["archive", id, workspace_public_id]
    end

    def restore_conversation(id, workspace_public_id:)
      @operations << ["restore", id, workspace_public_id]
    end

    def fork_conversation(id, turn, idempotency_key:, workspace_public_id:)
      @operations << ["fork", id, turn, idempotency_key, workspace_public_id]
      @forks[idempotency_key] ||= { "conversation" => "fork-#{@forks.length + 1}", "position" => 0 }
      @open_workspaces[@forks.fetch(idempotency_key).fetch("conversation")] = workspace_public_id
      if @fail_fork
        @fail_fork = false
        raise Rho::ConnectionError, "Fork accepted but response lost"
      end
      @forks.fetch(idempotency_key)
    end

    def attach(id, workspace_public_id:)
      @attaches << [id, workspace_public_id]
    end

    def variants(id, turn, workspace_public_id:)
      @decks.fetch([id, turn], [])
    end

    def regenerate(id, turn, workspace_public_id:, idempotency_key:)
      @regeneration_keys << idempotency_key
      @operations << ["regenerate", id, turn, workspace_public_id]
      @decks.fetch([id, turn]) << { "public_id" => VARIANT_ID, "status" => "running", "run_public_id" => "loop-regenerated" }
      if @fail_regenerate
        @fail_regenerate = false
        raise Rho::ConnectionError, "Regeneration accepted but response lost"
      end
      { "variant" => VARIANT_ID }
    end

    def activate_variant(id, turn, variant, workspace_public_id:)
      @operations << ["activate", id, turn, variant, workspace_public_id]
      @turn_rows.fetch(id).find { |row| row.fetch("public_id") == turn }["variant_public_id"] = variant
      @decks.fetch([id, turn]).find { |row| row.fetch("public_id") == variant }
    end

    def edit_turn(id, turn, text:, workspace_public_id:)
      @operations << ["edit", id, turn, text, workspace_public_id]
      { "public_id" => "edited-variant" }
    end

    def candidate_view_state(id, turn, variant, concealed:, workspace_public_id:)
      @operations << ["candidate_view", id, turn, variant, concealed, workspace_public_id]
    end

    def delete_turn(id, turn, workspace_public_id:)
      @operations << ["undo", id, turn, workspace_public_id]
    end

    def turn_view_state(id, turn, workspace_public_id:, **fields)
      @operations << ["view", id, turn, fields, workspace_public_id]
    end

    def execution_control(action, id, task_key: nil, workspace_public_id:)
      row = [action, id]
      row << task_key if task_key
      @operations << row.append(workspace_public_id)
      fail_response
    end

    def transcript(id, workspace_public_id:, **fields)
      row = ["transcript", id]
      row << fields if fields.any?
      @operations << row.append(workspace_public_id)
      @transcript_page || { "rounds" => [{ "content" => "Tool trace" }] }
    end

    def context_preview(id, model:, isolated: false, workspace_public_id:)
      @operations << ["context", id, model, isolated, workspace_public_id]
      { "input_tokens" => 120, "entries" => ["Prompt context"] }
    end

    def compact(id, workspace_public_id:)
      @operations << ["compact", id, workspace_public_id]
    end

    def fail_response
      if @fail_control
        @fail_control = false
        raise Rho::ConnectionError, "Control accepted but response lost"
      end
      {}
    end
  end

  def setup
    super
    @bridge = HistoryBridge.new
    @runtime = runtime
  end

  def test_history_and_search_do_not_create_a_conversation
    @runtime.consume(telegram_message(1, "/history"))
    @runtime.consume(telegram_message(2, "/search launch"))
    assert_includes feedback(1), "No conversation is open"
    assert_includes feedback(2), "No conversations are saved"
    assert_empty @bridge.opened
  end

  def test_history_bounded_windows_preserve_ids_and_original_workspace
    open_history
    @bridge.default_workspace = @bridge.workspace_rows.last
    @bridge.history_rows["conversation-1"] = [{ "public_id" => "turn-0", "position" => 0, "prompt" => "Question", "content" => "Answer" }]
    @runtime.consume(telegram_message(2, "/history"))
    @runtime.consume(telegram_message(3, "/history before 3"))
    assert_includes feedback(2), "Turn 0 · turn-0\nQuestion\nAnswer"
    assert_includes feedback(2), "/history before 3"
    refute_includes feedback(3), "Older history"
    assert_equal [["conversation-1", nil, "workspace-home"], ["conversation-1", 3, "workspace-home"]], @bridge.history_calls
  end

  def test_search_filters_foreign_conversations_before_rendering_and_pages_exact_workspace
    open_history(user: 2, chat: -10, topic: 4)
    @runtime.consume(telegram_message(2, "/new", chat: -10, topic: 4))
    @bridge.search_pages[["workspace-home", nil]] = {
      "matches" => [match("conversation-2", "private owner content"), match("conversation-1", "my launch")],
      "pagination" => { "next_after" => "cursor-2" },
    }
    @runtime.consume(telegram_message(3, "/search launch", user: 2, chat: -10, topic: 4))
    assert_includes feedback(3), "my launch"
    refute_includes feedback(3), "private owner content"
    assert_includes feedback(3), "/search next"
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    @runtime.consume(telegram_message(4, "/search next", user: 2, chat: -10, topic: 4))
    assert_equal [["launch", nil, "workspace-home"], ["launch", "cursor-2", "workspace-home"]], @bridge.history_calls
    @runtime.consume(telegram_message(5, "/search next", user: 2, chat: -10, topic: 5))
    assert_includes feedback(5), "No search continuation"
  end

  def test_lifecycle_changes_use_saved_route_and_restore_can_name_an_archived_session
    open_history
    @runtime.consume(telegram_message(2, "/rename A clearer title"))
    @runtime.consume(telegram_message(3, "/archive"))
    @runtime.consume(telegram_message(4, "/workspace use workspace-project"))
    @runtime.consume(telegram_message(5, "/restore conversation-1"))
    @runtime.consume(telegram_message(6, "/restore unknown"))
    assert_equal [["rename", "conversation-1", "A clearer title", "workspace-home"],
      ["archive", "conversation-1", "workspace-home"], ["restore", "conversation-1", "workspace-home"]], @bridge.operations
    assert_includes feedback(6), "not available in this chat/topic"
    assert_equal "conversation-2", route.fetch("current")
  end

  def test_ambiguous_non_idempotent_control_is_not_applied_again_after_restart
    open_history
    update = telegram_message(2, "/rename New title")
    @bridge.fail_control = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    assert_equal "applying", @state.read.fetch("pending_update").fetch("control_status")
    @runtime = runtime
    @runtime.consume(update)
    assert_equal 1, @bridge.operations.length
    assert_includes feedback(2), "was not repeated"
  end

  def test_fork_retries_the_frozen_turn_and_idempotency_key_without_resetting_old_cursor
    open_history
    @state.change { |document| document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")["position"] = 0 }
    update = telegram_message(2, "/fork")
    @bridge.fail_fork = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @bridge.turn_rows["conversation-1"] << turn(1, "Later turn")
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    @runtime.consume(update)
    assert_equal 1, @bridge.forks.length
    assert_equal ["turn-0", "turn-0"], @bridge.operations.map { |row| row[2] }
    assert_equal ["telegram:42:2:fork"] * 2, @bridge.operations.map { |row| row[3] }
    assert_equal "fork-1", route.fetch("current")
    assert_equal "workspace-home", route.fetch("workspace_public_id")
    assert_equal 0, route.fetch("conversations").fetch("conversation-1").fetch("position")
    assert_equal [["fork-1", "workspace-home"]], @bridge.attaches
    @runtime.consume(telegram_message(3, "Continue branch"))
    assert_equal "fork-1", @bridge.inputs.values.last.fetch(:conversation_id)
  end

  def test_history_edit_undo_and_mid_history_visibility_use_distinct_doors
    open_history
    @runtime.consume(telegram_message(2, "/edit 0 Corrected answer"))
    @runtime.consume(telegram_message(3, "/undo"))
    @runtime.consume(telegram_message(4, "/history delete original-turn"))
    @runtime.consume(telegram_message(5, "/history restore original-turn"))
    @runtime.consume(telegram_message(6, "/history exclude original-turn"))
    assert_equal [["edit", "conversation-1", "turn-0", "Corrected answer", "workspace-home"],
      ["undo", "conversation-1", "turn-0", "workspace-home"],
      ["view", "conversation-1", "original-turn", { concealed: true }, "workspace-home"],
      ["view", "conversation-1", "original-turn", { concealed: false }, "workspace-home"],
      ["view", "conversation-1", "original-turn", { visibility: "excluded_from_context" }, "workspace-home"]], @bridge.operations
    assert_includes feedback(2), "original remains"
  end

  def test_regeneration_delivers_new_candidate_once_at_an_already_read_position_and_keeps_old_task_identity
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    assert_equal ["telegram:42:2:regenerate"], @bridge.regeneration_keys
    assert_includes feedback(2), "Task: #{VARIANT_ID}"
    @runtime.consume(telegram_message(3, "/stop"))
    @runtime.consume(telegram_message(4, "/stop #{INPUT_ID}"))
    assert_equal ["loop-regenerated", "loop-1"], @bridge.stop_calls.map { |row| row.first }
    finish_candidate
    @runtime = runtime
    6.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
    assert_equal 1, sent_texts.count("Old answer")
    assert_equal 0, route.fetch("conversations").fetch("conversation-1").fetch("position")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
    candidate_request = @state.read.fetch("requests").values.find { |row| row["variant_id"] == VARIANT_ID }
    assert_equal "loop-regenerated", candidate_request.fetch("run_id")
    assert_includes @state.read.fetch("messages").values, "telegram:42:candidate:#{VARIANT_ID}"
  end

  def test_lost_regeneration_reply_still_follows_the_new_variant_without_resubmitting
    open_history
    deliver_old_answer
    @bridge.fail_regenerate = true
    update = telegram_message(2, "/regenerate")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    assert route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches").values.any? { |row| row["turn_id"] == "turn-0" }
    @runtime = runtime
    @runtime.consume(update)
    assert_equal 1, @bridge.operations.count { |row| row.first == "regenerate" }
    finish_candidate
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
    @runtime.consume(telegram_message(3, "/task pause #{VARIANT_ID}"))
    assert_equal ["pause", "loop-regenerated", "workspace-home"], @bridge.operations.last
  end

  def test_busy_regeneration_keeps_the_accepted_candidates_delivery_after_restart
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @state.change do |document|
      document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")
        .fetch("candidate_watches").fetch("turn-0").delete("turn_id")
    end
    @bridge.define_singleton_method(:regenerate) do |*_arguments, **_fields|
      raise Rho::Core::Refused.new("A turn is running", code: "conversation_busy", status: 409)
    end
    @runtime.consume(telegram_message(3, "/regenerate"))
    assert_includes feedback(3), "A turn is running"
    finish_candidate
    @runtime = runtime
    6.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
    assert_equal 1, sent_texts.count("Old answer")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
  end

  def test_unknown_busy_regeneration_retains_the_first_candidate_without_repeating_the_write
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.define_singleton_method(:regenerate) do |id, turn, workspace_public_id:, idempotency_key:|
      @operations << ["regenerate", id, turn, workspace_public_id]
      raise Rho::ConnectionError, "Response lost before the busy refusal was read"
    end
    update = telegram_message(3, "/regenerate")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @runtime = runtime
    @runtime.consume(update)
    finish_candidate
    6.times { @now += 6; @runtime.tick }
    assert_equal 2, @bridge.operations.count { |row| row.first == "regenerate" }
    assert_equal 1, sent_texts.count("New candidate answer")
    assert_equal 1, sent_texts.count("Old answer")
  end

  def test_a_regeneration_door_refusal_keeps_the_previous_failure_observation
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.define_singleton_method(:regenerate) do |*_arguments, **_fields|
      { "world" => { "door_refused" => "conversation_busy" } }
    end
    @runtime.consume(telegram_message(3, "/regenerate"))
    assert_includes feedback(3), "Regeneration refused: conversation_busy"
    @bridge.decks.fetch(["conversation-1", "turn-0"]).last["status"] = "failed"
    @runtime = runtime
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count { |text| text.include?("new candidate failed") }
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
  end

  def test_candidate_preflight_failure_preserves_the_existing_delivery
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.define_singleton_method(:variants) do |id, turn, workspace_public_id:|
      singleton_class.remove_method(:variants)
      raise Rho::Core::Refused.new("Candidate read refused", code: "forbidden", status: 403)
    end
    @runtime.consume(telegram_message(3, "/edit 0 Replacement"))
    assert_includes feedback(3), "Candidate read refused"
    assert_equal ["regenerate"], @bridge.operations.map(&:first)
    finish_candidate
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
  end

  def test_a_refusal_reading_an_accepted_candidate_does_not_undo_its_delivery_watch
    open_history
    deliver_old_answer
    @bridge.define_singleton_method(:regenerate) do |id, turn, workspace_public_id:, idempotency_key:|
      result = super(id, turn, workspace_public_id: workspace_public_id, idempotency_key: idempotency_key)
      define_singleton_method(:variants) do |*_arguments, **_fields|
        singleton_class.remove_method(:variants)
        raise Rho::Core::Refused.new("Candidate read refused", code: "forbidden", status: 403)
      end
      result
    end
    @runtime.consume(telegram_message(2, "/regenerate"))
    assert_includes feedback(2), "Candidate read refused"
    @runtime = runtime
    @runtime.consume(telegram_message(2, "/regenerate"))
    assert_equal 1, @bridge.operations.count { |row| row.first == "regenerate" }
    finish_candidate
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
  end

  def test_reselecting_an_undelivered_active_candidate_keeps_its_delivery
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    finish_candidate
    @runtime.consume(telegram_message(3, "/variant 0 #{VARIANT_ID}"))
    @runtime = runtime
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("New candidate answer")
    assert_equal "activate", @bridge.operations.last.first
  end

  def test_lost_candidate_activation_preserves_both_observations_during_io
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.decks.fetch(["conversation-1", "turn-0"]) << {
      "public_id" => "selected-variant", "status" => "completed", "content" => "Selected answer",
    }
    follower = @runtime
    @bridge.define_singleton_method(:activate_variant) do |id, turn, variant, workspace_public_id:|
      @decks.fetch([id, turn]).find { |row| row.fetch("public_id") == VARIANT_ID }["status"] = "completed"
      @turn_rows.fetch(id).first.merge!("variant_public_id" => VARIANT_ID, "text" => "New candidate answer")
      # The follower can run while the member-plane write waits on HTTP.
      follower.tick
      super(id, turn, variant, workspace_public_id: workspace_public_id)
      @turn_rows.fetch(id).first["text"] = "Selected answer"
      raise Rho::ConnectionError, "Activation accepted but response lost"
    end
    update = telegram_message(3, "/variant 0 selected-variant")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @runtime = runtime
    @runtime.consume(update)
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, @bridge.operations.count { |row| row.first == "activate" }
    assert_equal 1, sent_texts.count("Selected answer")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
  end

  def test_an_older_follower_read_cannot_clear_a_newly_accepted_selection
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    finish_candidate
    @bridge.decks.fetch(["conversation-1", "turn-0"]) << {
      "public_id" => "selected-variant", "status" => "completed", "content" => "Selected answer",
    }
    select = -> { @runtime.consume(telegram_message(3, "/variant 0 selected-variant")) }
    @bridge.define_singleton_method(:variants) do |id, turn, workspace_public_id:|
      singleton_class.remove_method(:variants)
      select.call
      @turn_rows.fetch(id).first["text"] = "Selected answer"
      @decks.fetch([id, turn])
    end
    @runtime.tick
    3.times { @now += 6; @runtime.tick }
    assert_equal 1, sent_texts.count("Selected answer")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
  end

  def test_a_stale_pending_answer_does_not_remove_the_new_candidates_delivery
    open_history
    @state.change do |document|
      document.fetch("routes").fetch("1:0").fetch("conversations").fetch("conversation-1")["position"] = 0
      document.fetch("deliveries").clear
    end
    @state.enqueue("old", route: route, text: "Old pending answer", conversation_id: "conversation-1", turn_id: "turn-0",
      position: 0, variant_public_id: "conversation-1-variant-0")
    @runtime.consume(telegram_message(2, "/regenerate"))
    finish_candidate
    3.times { @now += 6; @runtime.tick }
    refute_includes sent_texts, "Old pending answer"
    assert_equal 1, sent_texts.count("New candidate answer")
  end

  def test_failed_candidate_reports_failure_and_preserves_original_answer
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.decks.fetch(["conversation-1", "turn-0"]).last["status"] = "failed"
    2.times { @now += 6; @runtime.tick }
    assert sent_texts.any? { |text| text.include?("new candidate failed") }
    assert_equal "conversation-1-variant-0", @bridge.turn_rows.fetch("conversation-1").first.fetch("variant_public_id")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
  end

  def test_unreadable_candidate_source_retires_the_watch_and_unsent_reply
    open_history
    deliver_old_answer
    @runtime.consume(telegram_message(2, "/regenerate"))
    @bridge.define_singleton_method(:variants) do |*_arguments, **_fields|
      raise Rho::Core::Refused.new("No access", code: "forbidden", status: 403)
    end
    2.times { @now += 6; @runtime.tick }
    assert_empty route.fetch("conversations")
    assert_equal "conversation-1", route.fetch("current")
    refute_includes sent_texts, "New candidate answer"
    assert sent_texts.any? { |text| text.include?("no longer readable") }
  end

  def test_deleting_the_watched_turn_before_reconciliation_keeps_the_conversation_followed
    open_history
    @runtime.consume(telegram_message(2, "/edit 0 Replacement"))
    @bridge.turn_rows["conversation-1"] = []
    @bridge.define_singleton_method(:variants) do |*_arguments, **_fields|
      raise Rho::Core::Refused.new("Turn was deleted", code: "not_found", status: 404)
    end
    @runtime.tick
    assert_equal "conversation-1", route.fetch("current")
    assert_empty route.fetch("conversations").fetch("conversation-1").fetch("candidate_watches")
    refute sent_texts.any? { |text| text.include?("no longer readable") }
  end

  def test_non_owner_regeneration_and_resume_require_existing_read_only_execution
    open_history(user: 2, chat: -10, topic: 4)
    @bridge.execution_tools["loop-1"] = ["bash"]
    @runtime.consume(telegram_message(2, "/regenerate", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(3, "/task resume", user: 2, chat: -10, topic: 4))
    @runtime.consume(telegram_message(4, "/task retry", user: 2, chat: -10, topic: 4))
    assert_empty @bridge.operations
    [2, 3, 4].each { |id| assert_includes feedback(id), "verified read-only" }
    @bridge.execution_tools["loop-1"] = ["read"]
    @runtime.consume(telegram_message(5, "/regenerate", user: 2, chat: -10, topic: 4))
    assert_equal "regenerate", @bridge.operations.last.first
    @runtime.consume(telegram_message(6, "/task pause #{VARIANT_ID}", chat: -10, topic: 5))
    assert_includes feedback(6), "not available in this chat/topic"
    assert_equal 1, @bridge.operations.length
  end

  def test_non_owner_regeneration_refuses_owner_answerer_or_default_memory_but_accepts_explicit_off
    open_history(user: 2, chat: -10, topic: 4)
    original = @bridge.turn_rows.fetch("conversation-1").first
    original["answering_user_public_id"] = "owner-profile"
    @runtime.consume(telegram_message(2, "/regenerate", user: 2, chat: -10, topic: 4))
    original["answering_user_public_id"] = "group-profile"
    original["memory_context"] = nil
    @runtime.consume(telegram_message(3, "/regenerate", user: 2, chat: -10, topic: 4))
    original.delete("memory_context")
    @runtime.consume(telegram_message(4, "/regenerate", user: 2, chat: -10, topic: 4))
    assert_empty @bridge.operations
    [2, 3, 4].each { |id| assert_includes feedback(id), "Start a new request or ask the bot owner" }

    original["memory_context"] = { "bindings" => [] }
    @runtime.consume(telegram_message(5, "/regenerate", user: 2, chat: -10, topic: 4))
    assert_equal [["regenerate", "conversation-1", "turn-0", "workspace-home"]], @bridge.operations
  end

  def test_owner_can_regenerate_their_turn_with_default_memory
    open_history
    original = @bridge.turn_rows.fetch("conversation-1").first
    original["answering_user_public_id"] = "owner-profile"
    original["memory_context"] = nil
    @runtime.consume(telegram_message(2, "/regenerate"))
    assert_equal [["regenerate", "conversation-1", "turn-0", "workspace-home"]], @bridge.operations
  end

  def test_execution_and_context_commands_retain_workspace_after_restart
    open_history
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    ["/task pause", "/task resume", "/task retry", "/task abandon", "/transcript", "/context", "/compact"].each_with_index do |command, index|
      @runtime.consume(telegram_message(index + 2, command))
    end
    assert_equal %w[pause resume retry abandon transcript context compact], @bridge.operations.map(&:first)
    assert_equal ["workspace-home"] * 7, @bridge.operations.map(&:last)
    assert_includes feedback(6), "Tool trace"
    assert_includes feedback(7), "Prompt context"
  end

  def test_nonowner_fork_context_binds_memory_and_selects_the_isolated_answerer
    open_history(user: 2)
    @runtime.consume(telegram_message(2, "/fork", user: 2))
    @runtime.consume(telegram_message(3, "/context", user: 2))
    bindings = @bridge.memory_bindings.fetch("fork-1").fetch("bindings")
    assert_equal %w[conversation person], bindings.map { |row| row.fetch("name") }
    assert_equal ["context", "fork-1", nil, true, "workspace-home"], @bridge.operations.last
    assert_includes feedback(3), "Prompt context"
  end

  def test_candidate_activation_and_visibility_keep_the_same_turn_and_original_candidate
    open_history
    deliver_old_answer
    @bridge.decks.fetch(["conversation-1", "turn-0"]) << { "public_id" => VARIANT_ID, "status" => "completed", "content" => "Alternative", "run_public_id" => "alternate-loop" }
    @runtime.consume(telegram_message(2, "/variants 0"))
    assert_includes feedback(2), "conversation-1-variant-0"
    assert_includes feedback(2), VARIANT_ID
    @runtime.consume(telegram_message(3, "/variant 0 #{VARIANT_ID}"))
    @runtime.consume(telegram_message(4, "/variant 0 conversation-1-variant-0 hide"))
    @runtime.consume(telegram_message(5, "/variant 0 conversation-1-variant-0 restore"))
    assert_equal ["activate", "conversation-1", "turn-0", VARIANT_ID, "workspace-home"], @bridge.operations.first
    assert_equal [["candidate_view", "conversation-1", "turn-0", "conversation-1-variant-0", true, "workspace-home"],
      ["candidate_view", "conversation-1", "turn-0", "conversation-1-variant-0", false, "workspace-home"]], @bridge.operations.last(2)
    @runtime.consume(telegram_message(6, "/stop"))
    assert_equal "alternate-loop", @bridge.stop_calls.last.first
    assert_equal 2, @bridge.decks.fetch(["conversation-1", "turn-0"]).length
  end

  def test_transcript_branch_pages_and_explicit_failed_task_keys_are_reachable
    open_history
    @bridge.transcript_page = { "rounds" => [], "has_older" => true, "next_before" => "r4" }
    @runtime.consume(telegram_message(2, "/transcript #{INPUT_ID} branch r1.c1 before r8"))
    assert_equal ["transcript", "loop-1", { prefix: "r1.c1", before: "r8" }, "workspace-home"], @bridge.operations.last
    assert_includes feedback(2), "/transcript #{INPUT_ID} branch r1.c1 before r4"
    @runtime.consume(telegram_message(3, "/task retry #{INPUT_ID} r1.c2"))
    assert_equal ["retry", "loop-1", "r1.c2", "workspace-home"], @bridge.operations.last
    @runtime.consume(telegram_message(4, "/task abandon #{INPUT_ID} r1.c3"))
    assert_equal ["abandon", "loop-1", "r1.c3", "workspace-home"], @bridge.operations.last
    @runtime.consume(telegram_message(5, "/task pause #{INPUT_ID} r1.c2"))
    assert_includes feedback(5), "Retry and abandon"
    assert_equal 3, @bridge.operations.length
  end

  def test_regenerated_background_receipt_and_question_keep_candidate_request_ownership
    open_history(user: 2, chat: -10, topic: 4)
    @runtime.consume(telegram_message(2, "/regenerate", user: 2, chat: -10, topic: 4))
    @bridge.event_rows["conversation-1"] = [
      ["input_accepted", { "input_public_id" => "background-input", "origin" => "task_result", "run_public_id" => "loop-regenerated" }],
      ["input_materialized", { "input_public_id" => "background-input", "turn_public_id" => "turn-1" }],
      ["turn_status", { "turn_public_id" => "turn-1", "run_public_id" => "background-loop" }],
    ].each_with_index.map { |(type, payload), index| { "type" => type, "payload" => payload, "sequence" => index + 1, "cursor" => "e#{index}" } }
    @bridge.pending_rows = [{ "kind" => "ask", "run_public_id" => "loop-regenerated", "task_key" => "ask-1",
      "question" => "Choose an option", "workspace_public_id" => "workspace-home" }]
    finish_candidate
    @bridge.turn_rows["conversation-1"] << turn(1, "Background candidate result")
    3.times { @now += 6; @runtime.tick }
    assert_equal "telegram:42:candidate:#{VARIANT_ID}", @state.read.fetch("work").fetch("background-input").fetch("request_id")
    question_id = @state.read.fetch("questions").keys.first
    @runtime.consume(telegram_message(3, "/answer #{question_id} yes", user: 2, chat: -10, topic: 4))
    assert_equal ["answer", "loop-regenerated", "ask-1", "yes", "workspace-home"], @bridge.decisions.last
    @runtime.consume(telegram_message(4, "/task pause #{VARIANT_ID}", user: 2, chat: -10, topic: 4))
    assert_equal ["pause", "loop-regenerated", "workspace-home"], @bridge.operations.last
  end

  private

    def open_history(**fields)
      @runtime.consume(telegram_message(1, "@rho_bot Start a task", entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }], **fields))
      @bridge.turn_rows["conversation-1"] = [turn(0, "Old answer").merge("run_public_id" => "loop-1",
        "answering_user_public_id" => "group-profile", "memory_context" => { "bindings" => [] })]
      @bridge.decks[["conversation-1", "turn-0"]] = [{ "public_id" => "conversation-1-variant-0", "status" => "completed",
        "active" => true, "content" => "Old answer", "run_public_id" => "loop-1" }]
    end

    def deliver_old_answer
      @state.change { |document| document.fetch("deliveries").clear }
      @runtime.tick
      @now += 6
    end

    def finish_candidate
      @bridge.decks.fetch(["conversation-1", "turn-0"]).last.merge!("status" => "completed", "active" => true)
      @bridge.turn_rows["conversation-1"] = [turn(0, "New candidate answer").merge("variant_public_id" => VARIANT_ID, "run_public_id" => "loop-regenerated")]
    end

    def match(id, text)
      { "conversation_public_id" => id, "title" => "Title", "excerpt" => text, "position" => 0 }
    end

    def route = @state.read.fetch("routes").fetch("1:0")
    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
    def sent_texts = @client.calls.filter_map { |name, fields| fields[:text] if name == "sendMessage" }
end
