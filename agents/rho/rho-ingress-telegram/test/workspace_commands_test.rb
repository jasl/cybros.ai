require "support/runtime"

class TelegramWorkspaceCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_workspace_listing_is_mechanical_and_marks_the_current_selection
    @runtime.consume(telegram_message(1, "/workspace"))
    assert_includes reply(1), "Home (workspace-home)"
    assert_includes reply(1), "Project (workspace-project)"
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
  end

  def test_switch_starts_a_new_conversation_and_keeps_old_background_work_after_restart
    @runtime.consume(telegram_message(1, "start"))
    @runtime.consume(telegram_message(2, "/workspace use Project"))
    route = @state.read.fetch("routes").fetch("1:0")
    assert_equal "workspace-project", route.fetch("workspace_public_id")
    assert_equal "conversation-2", route.fetch("current")
    assert_equal %w[conversation-1 conversation-2], route.fetch("conversations").keys
    assert_equal "workspace-home", @bridge.default_workspace.fetch("public_id")

    @runtime = runtime
    @runtime.consume(telegram_message(3, "new project question"))
    assert_equal "conversation-2", @bridge.inputs.fetch("telegram:42:3:input").fetch(:conversation_id)
    @bridge.turn_rows["conversation-1"] = [turn(0, "Old background answer")]
    @runtime.tick
    assert_equal "Old background answer", @state.read.fetch("deliveries").fetch("turn:conversation-1:turn-0:conversation-1-variant-0").fetch("text")
    @runtime.consume(telegram_message(4, "/new"))
    assert_equal "workspace-project", @bridge.open_workspaces.values.last
  end

  def test_workspace_selection_is_per_topic_and_group_changes_require_the_owner
    @runtime.consume(telegram_message(1, "/workspace use Project", chat: -10, topic: 4, user: 2))
    assert_includes reply(1), "Only the bot owner"
    assert_empty @bridge.opened
    @runtime.consume(telegram_message(2, "/workspace use workspace-project", chat: -10, topic: 4))
    @runtime.consume(telegram_message(3, "/new", chat: -10, topic: 5))
    routes = @state.read.fetch("routes")
    assert_equal "workspace-project", routes.fetch("-10:4:1").fetch("workspace_public_id")
    assert_equal "workspace-home", routes.fetch("-10:5:1").fetch("workspace_public_id")
    @runtime.consume(telegram_message(4, "/workspace current", chat: -10, topic: 4))
    assert_includes reply(4), "Project (workspace-project)"
  end

  def test_old_question_remains_answerable_after_switch_and_restart
    @runtime.consume(telegram_message(1, "start"))
    old_question = { "workspace_public_id" => "workspace-home", "run_public_id" => "old-child-loop", "task_key" => "question", "kind" => "ask",
      "question" => "Continue the old work?" }
    @bridge.define_singleton_method(:pending) { |id, **| id == "conversation-1" ? [old_question] : [] }
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)

    @runtime.consume(telegram_message(2, "/workspace use Project"))
    @runtime = runtime
    @runtime.tick
    refute @state.read.fetch("questions").fetch(id).fetch("resolved", false)
    @runtime.consume(telegram_message(3, "/answer #{id} yes"))

    assert_equal [["answer", "old-child-loop", "question", "yes", "workspace-home"]], @bridge.decisions
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
    assert_equal 1, @bridge.inputs.length
    assert_includes reply(3), "Response accepted."
  end

  def test_missing_and_ambiguous_names_leave_the_existing_conversation_unchanged
    @runtime.consume(telegram_message(1, "start"))
    @runtime.consume(telegram_message(2, "/workspace use Missing"))
    assert_includes reply(2), "not available"
    @bridge.workspace_rows << { "public_id" => "workspace-other", "name" => "Project", "status" => "active" }
    @runtime.consume(telegram_message(3, "/workspace use Project"))
    assert_includes reply(3), "public ID"
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("1:0").fetch("current")
    assert_equal 1, @bridge.opened.length
  end

  def test_create_replays_a_lost_reply_without_creating_another_workspace
    @bridge.fail_workspace = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(telegram_message(1, "/workspace create 新项目")) }
    assert_nil @state.read["offset"]
    @runtime = runtime
    @runtime.consume(telegram_message(1, "/workspace create 新项目"))
    assert_equal 1, @bridge.created_workspaces.length
    assert_equal "新项目", @bridge.created_workspaces.fetch("telegram:42:1:workspace").fetch("name")
    assert_equal "workspace-created-1", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
    assert_equal 1, @bridge.opened.length
  end

  def test_open_replay_keeps_the_workspace_selected_before_the_lost_response
    @bridge.fail_open = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(telegram_message(1, "start")) }
    assert_equal "workspace-home", @state.read.fetch("pending_update").fetch("workspace_public_id")
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    @runtime.consume(telegram_message(1, "start"))
    assert_equal 1, @bridge.opened.length
    assert_equal ["workspace-home"], @bridge.open_workspaces.values
    assert_equal "workspace-home", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
  end

  def test_switch_replay_uses_the_staged_identity_even_if_its_name_changes
    @runtime.consume(telegram_message(1, "start"))
    @bridge.fail_open = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(telegram_message(2, "/workspace use Project")) }
    @bridge.workspace_rows.last["name"] = "Renamed"
    @runtime = runtime
    @runtime.consume(telegram_message(2, "/workspace use Project"))

    assert_equal 2, @bridge.opened.length
    assert_equal "workspace-project", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
    assert_includes reply(2), "Renamed (workspace-project)"
  end

  def test_unavailable_default_still_lists_choices_and_allows_recovery
    @bridge.default_workspace = nil
    @bridge.workspace_selection = "deleted-workspace"
    @runtime.consume(telegram_message(1, "/workspace list"))
    assert_includes reply(1), "Unavailable (deleted-workspace)"
    assert_includes reply(1), "Project (workspace-project)"
    assert_nil @state.read["pending_update"]
    @runtime.consume(telegram_message(2, "/workspace use Project"))
    assert_equal "workspace-project", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
  end

  def test_archived_route_selection_does_not_block_listing_or_switching
    @runtime.consume(telegram_message(1, "start"))
    @bridge.workspace_rows.shift
    @runtime.consume(telegram_message(2, "/workspace"))
    assert_includes reply(2), "Unavailable (workspace-home)"
    assert_includes reply(2), "Project (workspace-project)"
    @runtime.consume(telegram_message(3, "/workspace use Project"))
    assert_equal "conversation-2", @state.read.fetch("routes").fetch("1:0").fetch("current")
  end

  def test_first_message_with_unavailable_default_is_consumed_before_a_recovery_command
    @bridge.default_workspace = nil
    @bridge.workspace_selection = "deleted-workspace"
    # Use the real Bridge boundary for its nil-workspace classification.
    core = Object.new
    listing = @bridge.workspace_state
    core.define_singleton_method(:workspaces) { listing }
    real_bridge = Rho::IngressTelegram::Bridge.new(host: nil, core: core)
    @bridge.define_singleton_method(:default_workspace) { real_bridge.default_workspace }

    @runtime.consume(telegram_message(1, "hello"))
    assert_includes reply(1), "/workspace"
    assert_nil @state.read["pending_update"]
    assert_equal 2, @state.read.fetch("offset")
    assert_empty @bridge.inputs
    @runtime.consume(telegram_message(2, "/workspace use Project"))
    assert_equal "workspace-project", @state.read.fetch("routes").fetch("1:0").fetch("workspace_public_id")
  end

  def test_existing_conversation_without_a_saved_selection_keeps_its_original_workspace
    @runtime.consume(telegram_message(1, "start"))
    @state.change { |document| document.fetch("routes").fetch("1:0").delete("workspace_public_id") }
    @bridge.default_workspace = @bridge.workspace_rows.last
    @bridge.workspace_selection = "workspace-project"
    @runtime.consume(telegram_message(2, "/workspace current"))
    assert_includes reply(2), "Current workspace: Home (workspace-home)"

    @bridge.define_singleton_method(:conversation_workspace_id) do |_id|
      raise Rho::Core::Refused.new("Not found", code: "not_found", status: 404)
    end
    @runtime.consume(telegram_message(3, "/workspace list"))
    assert_includes reply(3), "Current workspace: Unavailable"
    assert_includes reply(3), "Project (workspace-project)"
    refute_includes reply(3), "Current workspace: Project"
    assert_nil @state.read["pending_update"]
  end

  private

    def reply(id)
      @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
    end
end
