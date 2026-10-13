require "support/runtime"

class TelegramWorkspaceCommandsTest < Minitest::Test
  include TelegramRuntimeSupport

  class SwitchBridge < TelegramRuntimeSupport::Bridge
    attr_accessor :fail_switch

    def new_bot_conversation(**fields)
      unless @default_workspace || fields[:home_workspace_public_id]
        raise Rho::Core::Refused.new("Choose this Bot's Home Workspace before opening its conversation", status: 409, code: "bot_home_required")
      end
      result = super
      if @fail_switch
        @fail_switch = false
        raise Rho::ConnectionError, "Core selected the conversation but its response was lost"
      end
      result
    end
  end

  def setup
    super
    @bridge = SwitchBridge.new
    @runtime = runtime
  end

  def test_workspace_listing_is_mechanical_and_marks_the_current_selection
    receive(telegram_message(1, "/workspace"))
    assert_includes reply(1), "Home (workspace-home)"
    assert_includes reply(1), "Project (workspace-project)"
    assert_empty @bridge.opened
    assert_empty @bridge.inputs
  end

  def test_switch_starts_a_new_conversation_and_keeps_old_background_work_after_restart
    receive(telegram_message(1, "start"))
    receive(telegram_message(2, "/workspace use Project"))
    route = @state.read.fetch("routes").fetch("#{CONNECTION}:1:0")
    assert_equal({ "public_id" => "conversation-2", "workspace_public_id" => "workspace-project" }, current)
    assert_equal %w[conversation-1 conversation-2], route.fetch("conversations").keys
    assert_equal "workspace-project", @bridge.bot_detail.fetch("bot").fetch("home_workspace_public_id")

    @runtime = runtime
    receive(telegram_message(3, "new project question"))
    assert_equal "conversation-2", @bridge.inputs.fetch("telegram:#{BOT}:#{CONNECTION}:42:3:input").fetch(:conversation_id)
    @bridge.turn_rows["conversation-1"] = [turn(0, "Old background answer")]
    @runtime.tick
    assert_equal "Old background answer", @state.read.fetch("deliveries").fetch("turn:conversation-1:turn-0:conversation-1-variant-0").fetch("text")
    receive(telegram_message(4, "/new"))
    assert_equal "workspace-project", @bridge.open_workspaces.values.last
  end

  def test_home_and_current_are_shared_by_group_members_and_only_the_owner_changes_them
    receive(telegram_message(1, "/workspace use Project", chat: -10, topic: 4, user: 2))
    assert_includes reply(1), "Only the bot owner"
    assert_empty @bridge.opened
    receive(telegram_message(2, "/workspace use workspace-project", chat: -10, topic: 4))
    receive(telegram_message(3, "/settings", chat: -10, topic: 4, user: 2))
    assert_includes reply(3), "Project (workspace-project)"
    assert_equal({ "public_id" => "conversation-1", "workspace_public_id" => "workspace-project" }, current)
    assert_equal "workspace-project", @bridge.bot_detail.fetch("bot").fetch("home_workspace_public_id")
    receive(telegram_message(4, "/workspace current", chat: -10, topic: 4))
    assert_includes reply(4), "Project (workspace-project)"
  end

  def test_old_question_remains_answerable_after_switch_and_restart
    receive(telegram_message(1, "start"))
    old_question = { "workspace_public_id" => "workspace-home", "run_public_id" => "old-child-loop", "task_key" => "question", "kind" => "ask",
      "question" => "Continue the old work?" }
    @bridge.define_singleton_method(:pending) { |id, **| id == "conversation-1" ? [old_question] : [] }
    @runtime.tick
    id = @state.read.fetch("questions").keys.fetch(0)

    receive(telegram_message(2, "/workspace use Project"))
    @runtime = runtime
    @runtime.tick
    refute @state.read.fetch("questions").fetch(id).fetch("resolved", false)
    receive(telegram_message(3, "/answer #{id} yes"))

    assert_equal [["answer", "old-child-loop", "question", "yes", "workspace-home"]], @bridge.decisions
    assert_equal "conversation-2", @bridge.bot_detail.fetch("current").fetch("public_id")
    assert_equal 1, @bridge.inputs.length
    assert_includes reply(3), "Response accepted."
  end

  def test_missing_and_ambiguous_names_leave_the_existing_conversation_unchanged
    receive(telegram_message(1, "start"))
    receive(telegram_message(2, "/workspace use Missing"))
    assert_includes reply(2), "not available"
    @bridge.workspace_rows << { "public_id" => "workspace-other", "name" => "Project", "status" => "active" }
    receive(telegram_message(3, "/workspace use Project"))
    assert_includes reply(3), "public ID"
    assert_equal "conversation-1", @bridge.bot_detail.fetch("current").fetch("public_id")
    assert_equal 1, @bridge.opened.length
  end

  def test_create_replays_a_lost_reply_without_creating_another_workspace
    @bridge.fail_workspace = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(1, "/workspace create 新项目")) }
    assert_nil @connection_state.read["offset"]
    @runtime = runtime
    receive(telegram_message(1, "/workspace create 新项目"))
    assert_equal 1, @bridge.created_workspaces.length
    assert_equal "新项目", @bridge.created_workspaces.fetch("telegram:#{BOT}:#{CONNECTION}:42:1:workspace").fetch("name")
    assert_equal "workspace-created-1", current.fetch("workspace_public_id")
    assert_equal "workspace-created-1", @bridge.bot_detail.fetch("bot").fetch("home_workspace_public_id")
    assert_equal 1, @bridge.opened.length
  end

  def test_open_replay_keeps_the_workspace_selected_before_the_lost_response
    @bridge.fail_switch = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(1, "start")) }
    assert_equal "workspace-home", current.fetch("workspace_public_id"), "Core retains the accepted locator before channel acknowledgement"
    @bridge.default_workspace = @bridge.workspace_rows.last
    @runtime = runtime
    receive(telegram_message(1, "start"))
    assert_equal 1, @bridge.opened.length
    assert_equal ["workspace-home"], @bridge.open_workspaces.values
    assert_equal "workspace-home", current.fetch("workspace_public_id")
    assert_equal "workspace-home", @bridge.inputs.values.last.fetch(:workspace_public_id)
  end

  def test_switch_replay_uses_the_staged_identity_even_if_its_name_changes
    receive(telegram_message(1, "start"))
    @bridge.fail_switch = true
    assert_raises(Rho::ConnectionError) { receive(telegram_message(2, "/workspace use Project")) }
    @bridge.workspace_rows.last["name"] = "Renamed"
    @runtime = runtime
    receive(telegram_message(2, "/workspace use Project"))

    assert_equal 2, @bridge.opened.length
    assert_equal "workspace-project", current.fetch("workspace_public_id")
    assert_includes reply(2), "Renamed (workspace-project)"
  end

  def test_unavailable_default_still_lists_choices_and_allows_recovery
    @bridge.default_workspace = nil
    @bridge.workspace_selection = "deleted-workspace"
    receive(telegram_message(1, "/workspace list"))
    assert_includes reply(1), "Unavailable (deleted-workspace)"
    assert_includes reply(1), "Project (workspace-project)"
    assert_nil @state.read["pending_update"]
    receive(telegram_message(2, "/workspace use Project"))
    assert_equal "workspace-project", current.fetch("workspace_public_id")
  end

  def test_archived_route_selection_does_not_block_listing_or_switching
    receive(telegram_message(1, "start"))
    @bridge.workspace_rows.shift
    receive(telegram_message(2, "/workspace"))
    assert_includes reply(2), "Unavailable (workspace-home)"
    assert_includes reply(2), "Project (workspace-project)"
    receive(telegram_message(3, "/workspace use Project"))
    assert_equal "conversation-2", @bridge.bot_detail.fetch("current").fetch("public_id")
  end

  def test_first_message_with_unavailable_default_is_consumed_before_a_recovery_command
    @bridge.default_workspace = nil
    @bridge.workspace_selection = "deleted-workspace"
    receive(telegram_message(1, "hello"))
    assert_includes reply(1), "Home Workspace"
    assert_nil @state.read["pending_update"]
    assert_equal 2, @connection_state.read.fetch("offset")
    assert_empty @bridge.inputs
    receive(telegram_message(2, "/workspace use Project"))
    assert_equal "workspace-project", current.fetch("workspace_public_id")
  end

  def test_existing_conversation_uses_its_core_locator_when_home_changes_and_adapter_selection_is_absent
    receive(telegram_message(1, "start"))
    refute @state.read.fetch("routes").fetch("#{CONNECTION}:1:0").key?("workspace_public_id")
    @bridge.default_workspace = @bridge.workspace_rows.last
    @bridge.workspace_selection = "workspace-project"
    receive(telegram_message(2, "/workspace current"))
    assert_includes reply(2), "Current workspace: Home (workspace-home)"

    @bridge.workspace_rows.shift
    receive(telegram_message(3, "/workspace list"))
    assert_includes reply(3), "Current workspace: Unavailable (workspace-home)"
    assert_includes reply(3), "Project (workspace-project)"
    refute_includes reply(3), "Current workspace: Project"
    assert_nil @state.read["pending_update"]
  end

  private

    def current = @bridge.bot_detail.fetch("current")

    def reply(id)
      @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:#{id}:reply").fetch("text")
    end
end
