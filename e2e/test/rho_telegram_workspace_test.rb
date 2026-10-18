require_relative "support/rho_telegram_case"
require_relative "support/rho_telegram_reminders"
require_relative "support/rho_telegram_destinations"

# Workspace switches, schedules and destinations preserve accepted work ownership.
class RhoTelegramWorkspaceTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramReminders
  include E2E::RhoTelegramDestinations

  def test_workspace_selection_preserves_original_work_across_chat_switch_and_daemon_restart
    boot_runtime(allowed: [101, 102])
    original_workspace = @workspace.public_id
    receive(update(1, "/new", chat: -10, topic: 7))
    receive(update(2, "/new", chat: -10, topic: 8))
    untouched_topic = current("-10:8")
    selected_workspace = nil
    original_conversation = nil

    assert_supplementary_delivery(answer_id: 100) do |conversation_id, question_id|
      original_conversation = conversation_id
      receive(update(8, "/workspace create Project two"))
      selected_workspace = @core.bot_detail(agent_public_id: bot_id_for("101:0")).dig("current", "workspace_public_id")
      refute_equal original_workspace, selected_workspace
      created = @client.workspaces.fetch(selected_workspace)
      assert_equal "Project two", created.name
      assert_equal "private", created.access_mode
      assert created.dedicated
      refute_equal conversation_id, current("101:0")
      assert state_for("101:0").read.fetch("routes").fetch(telegram_route_key("101:0")).fetch("conversations").key?(conversation_id)
      assert_equal original_workspace, @daemon.status.fetch("workspace").fetch("public_id")

      receive(update(9, "/workspace use #{selected_workspace}", chat: -10, topic: 7))
      assert_equal selected_workspace, @core.bot_detail(agent_public_id: bot_id_for("-10:7")).dig("current", "workspace_public_id")
      assert_equal untouched_topic, current("-10:8")
      assert_equal original_workspace, @core.conversation(untouched_topic).fetch("workspace_public_id")

      output, status = @daemon.cli("workspaces", "list")
      assert_predicate status, :success?, output
      assert_includes output, selected_workspace
      output, status = @daemon.cli("workspaces", "use", selected_workspace)
      assert_predicate status, :success?, output
      assert_equal original_workspace, @core.conversation(conversation_id).fetch("workspace_public_id")

      @runtime.close
      @daemon.stop
      @daemon.start
      await("persisted workspace selection after restart") do
        @daemon.status.dig("workspace", "public_id") == selected_workspace
      end
      connect_bridge(selected_workspace)
      boot_runtime(allowed: [101, 102])
      tick
      assert state_for("101:0").read.fetch("questions").key?(question_id), "the original question remains answerable"
      assert_equal original_workspace, @core.conversation(conversation_id).fetch("workspace_public_id")
      assert_equal untouched_topic, current("-10:8")
    end

    notes = CGI.escape(JSON.generate("path" => "conversation/workspace.md", "content" => "Keep working in the original workspace"))
    child_notes = CGI.escape(JSON.generate("path" => "conversation/workspace.md", "content" => "The waited child stays in its original workspace"))
    child_prompt = "!mock tool_call=memory_write:#{child_notes} reply=child-finished -- child work"
    spawn = CGI.escape(JSON.generate("prompt" => child_prompt, "role" => "worker", "label" => "workspace-child", "wait" => true))
    # The stateless mock counts the two earlier code/ask answers in history.
    script = "memory_write:#{notes},memory_write:#{notes},memory_write:#{notes}&spawn:#{spawn}"
    receive(update("resume-original-for-new-work", "/resume #{original_conversation}"))
    assert_equal original_conversation, current("101:0")
    @core.say(original_conversation, "!mock tool_call=#{script} -- update the old task", model: MODEL, workspace_public_id: original_workspace)
    old_chat = @workspace.conversation(original_conversation)
    memory_turn = await("a new tool-using turn in the original workspace") do
      replies = old_chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      replies.last if replies.length == 3
    end
    assert_includes successful_tool_output(memory_turn, "memory_write"), "Wrote conversation/workspace.md"
    assert_includes old_chat.memory.read("conversation/workspace.md").content, "Keep working in the original workspace"
    child = old_chat.children.items.find { |row| row.parent&.label == "workspace-child" }
    refute_nil child
    assert_includes @workspace.conversation(child.public_id).memory.read("conversation/workspace.md").content,
      "The waited child stays in its original workspace"

    receive(update("new-selected-workspace", "/new"))
    selected_chat = @client.workspace(selected_workspace).conversation(current("101:0"))
    receive(update(101, "!mock reply=selected-workspace -- a new workspace question"))
    assert_equal "Mock: selected-workspace", completed_reply(selected_chat).active_variant.content
    await("new workspace final delivery") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: selected-workspace" }
    end

    # A lost explicit default must never create a replacement, and it must not
    # prevent reading an old conversation or selecting an available workspace.
    selected = @human.workspace(selected_workspace)
    selected.archive(lock_version: @human.workspaces.fetch(selected_workspace).lock_version)
    assert_raises(Rho::Core::Refused) { @core.open_conversation }
    @runtime.close
    @daemon.stop
    @daemon.start
    await("the unavailable default is reported after restart") do
      @daemon.status.dig("workspace", "state") == "error"
    end
    connect_bridge(selected_workspace)
    boot_runtime(allowed: [101, 102])
    assert_raises(Rho::Core::Refused) { @core.open_conversation }
    assert_equal original_workspace, @core.conversation(original_conversation).fetch("workspace_public_id")
    assert_includes @core.workspaces.fetch("workspaces").map { |row| row.fetch("public_id") }, original_workspace

    command = CGI.escape(JSON.generate("command" => "printf original-workspace-after-restart"))
    script = (["bash:#{command}"] * 5).join(",")
    receive(update("resume-original-after-unavailable-home", "/resume #{original_conversation}"))
    @core.say(original_conversation, "!mock tool_call=#{script} -- check the original runner", model: MODEL, workspace_public_id: original_workspace)
    recovered = await("the original runner works despite an unavailable default") do
      replies = old_chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      replies.last if replies.length == 4
    end
    assert_includes successful_tool_output(recovered, "bash"), "original-workspace-after-restart"

    receive(update(102, "/workspace list"))
    assert_nil @state.read["pending_update"]
    receive(update(103, "/workspace use #{original_workspace}"))
    assert_equal original_workspace, @core.bot_detail(agent_public_id: bot_id_for("101:0")).dig("current", "workspace_public_id")
    output, status = @daemon.cli("workspaces", "use", original_workspace)
    assert_predicate status, :success?, output
    reopened = @core.open_conversation.fetch("conversation").fetch("public_id")
    assert_equal original_workspace, @core.conversation(reopened).fetch("workspace_public_id")
    assert_empty @logs
  end

  def test_busy_new_keeps_queued_speakers_and_a_late_subagent_in_the_archived_conversation
    boot_runtime(allowed: [101, 102])
    ask = CGI.escape(JSON.generate("prompt" => "Continue the original task?"))
    child_note = CGI.escape(JSON.generate("path" => "conversation/child.md", "content" => "The late child belongs to the original task."))
    spawn = CGI.escape(JSON.generate("role" => "worker", "label" => "late-worker", "wait" => true,
      "model" => "dev/mock-text-only", "prompt" => "!mock tool_call=memory_write:#{child_note} reply=late-child-finished -- retain this task"))
    receive(update("late-parent", "@rho_bot\n!mock tool_call=ask:#{ask},spawn:#{spawn} reply=original-finished -- original group task",
      chat: -10, topic: 7, mention: true))
    original_id = current("-10:7")
    original = @workspace.conversation(original_id)
    question_id, question = await("the original group task is waiting") do
      tick
      state_for("-10:7").read.fetch("questions").find { |_id, row| row["conversation_id"] == original_id && row["kind"] == "ask" }
    end
    parent = original.turns.list.items.find { |row| row.active_variant&.run_public_id == question.fetch("run_public_id") }
    assert_empty original.children.items
    note = CGI.escape(JSON.generate("path" => "speaker/queued.md", "content" => "Bob's accepted work completed after the switch."))
    # The original parent will contribute its ask and spawn results before this queued turn.
    receive(update("late-queued", "@rho_bot\n!mock tool_call=memory_ls,memory_ls,memory_write:#{note} reply=queued-finished -- Bob's queued task",
      user: 102, chat: -10, topic: 7, mention: true))
    queued = original.inputs.list.items.fetch(0)
    bob = state_for("-10:7").read.fetch("speakers").fetch("102")
    alice = state_for("-10:7").read.fetch("speakers").fetch("101")
    refute_equal alice, bob
    assert_equal "pending", queued.state
    telegram_control("late-new", "/new", chat: -10, topic: 7)
    selected_id = current("-10:7")
    refute_equal original_id, selected_id
    assert_predicate original.fetch, :archived?
    assert_equal [queued.public_id], original.inputs.list.items.map(&:public_id)
    assert_empty @workspace.conversation(selected_id).turns.list.items
    restart_group_runtime(allowed: [101, 102])
    telegram_control("late-answer", "/answer #{question_id} Continue", chat: -10, topic: 7)
    replies = await("old parent and queue finish after the switch") do
      tick
      rows = original.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      rows if rows.length == 2
    end
    assert_equal ["Mock: original-finished", "Mock: queued-finished"], replies.map { |turn| turn.active_variant.content }
    assert_equal parent.public_id, replies.first.public_id
    child = original.children.items.find { |row| row.parent&.label == "late-worker" }
    refute_nil child, "the child is born only after the already archived parent's answer"
    child_context = @workspace.conversation(child.public_id)
    assert_predicate child_context.fetch, :archived?
    child_reply = completed_reply(child_context)
    assert_equal "Mock: late-child-finished", child_reply.active_variant.content
    assert_equal "mock-text-only", child_reply.active_variant.model.model_ref
    assert_equal "explicit", child_reply.active_variant.model_selection.fetch("source")
    assert_equal "The late child belongs to the original task.", child_context.memory.read("conversation/child.md").content
    assert_equal "Bob's accepted work completed after the switch.", original.memory(speaker_public_id: bob).read("speaker/queued.md").content
    assert_raises(CybrosAgent::Api::NotFound) { original.memory(speaker_public_id: alice).read("speaker/queued.md") }
    assert_equal selected_id, current("-10:7")
    assert_empty @workspace.conversation(selected_id).turns.list.items
    await("both late results reach the original topic") do
      tick
      delivered = @telegram.formal(-10).map { |_method, row| row.fetch(:text) }
      delivered.include?("Mock: original-finished") && delivered.include?("Mock: queued-finished")
    end
    assert @telegram.formal(-10).all? { |_method, row| row.fetch(:message_thread_id) == 7 }
    assert_empty @logs
  ensure
    stop_group_work(original)
  end

  def test_a_waited_child_question_remains_answerable_when_the_new_default_is_unavailable
    boot_runtime(allowed: [101])
    receive(update(1, "/new"))
    original_id = current("101:0")
    original = @workspace.conversation(original_id)
    selected_id = @core.create_workspace(name: "Temporary default").fetch("public_id")
    @core.select_workspace(selected_id)
    @human.workspace(selected_id).archive(lock_version: @human.workspaces.fetch(selected_id).lock_version)
    @runtime.close
    @daemon.stop
    @daemon.start
    await("the archived explicit default is reported") { @daemon.status.dig("workspace", "state") == "error" }
    connect_bridge(selected_id)
    boot_runtime(allowed: [101])

    question = CGI.escape(JSON.generate("prompt" => "Continue the child in its original workspace?"))
    notes = CGI.escape(JSON.generate("path" => "conversation/workspace.md", "content" => "Answered in the original workspace"))
    child_prompt = "!mock tool_call=ask:#{question},memory_write:#{notes} reply=child-finished -- child question"
    spawn = CGI.escape(JSON.generate("prompt" => child_prompt, "role" => "worker", "label" => "asking-child", "wait" => true))
    @core.say(original_id, "!mock tool_call=spawn:#{spawn} reply=parent-finished -- waited child", model: MODEL, workspace_public_id: @workspace.public_id)
    question_id, pending = await("the unfollowed child's question in Telegram") do
      tick
      @state.read.fetch("questions").find { |_id, row| row.fetch("kind") == "ask" && !row["resolved"] }
    end
    assert_equal original_id, pending.fetch("conversation_id")
    assert_equal @workspace.public_id, pending.fetch("workspace_public_id")
    receive(update(2, "/answer #{question_id} Yes, continue."))
    assert @state.read.fetch("questions").fetch(question_id).fetch("resolved")
    assert_equal "Mock: parent-finished", completed_reply(original).active_variant.content
    child = original.children.items.find { |row| row.parent&.label == "asking-child" }
    refute_nil child
    assert_includes @workspace.conversation(child.public_id).memory.read("conversation/workspace.md").content,
      "Answered in the original workspace"
    assert_equal "error", @daemon.status.fetch("workspace").fetch("state")
    assert_empty @logs
  end
end
