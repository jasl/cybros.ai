require_relative "support/rho_telegram_case"
require_relative "support/rho_telegram_reminders"
require_relative "support/rho_telegram_destinations"

# Conversation controls and media cross the real daemon, Nexus and runner.
class RhoTelegramTest < E2E::RhoTelegramCase
  include E2E::RhoTelegramMedia
  include E2E::RhoTelegramCommands
  include E2E::RhoTelegramControls
  include E2E::RhoTelegramHistory
  include E2E::RhoTelegramReminders
  include E2E::RhoTelegramDestinations

  def test_allowed_speakers_group_privacy_replay_and_supplementary_delivery
    boot_runtime(allowed: [])
    @runtime.consume(update(1, "Do not admit this stranger", user: 999, chat: 999))
    assert_empty @state.read.fetch("speakers")
    assert_empty @state.read.fetch("routes")
    assert_empty @core.conversations.fetch("conversations")

    marker = "private-note-#{SecureRandom.hex(6)}"
    skill = "private-skill-#{SecureRandom.hex(6)}"
    @memory << @human.profile.memory.write("user/#{marker}.md", marker,
      expected_public_id: nil, expected_lock_version: nil)
    @memory << @human.profile.memory.write("user/skills/#{skill}", "Secret skill instructions.", description: skill,
      expected_public_id: nil, expected_lock_version: nil)
    boot_runtime(allowed: [101, 102])
    discover = CGI.escape(JSON.generate("query" => "skill"))
    private_update = update(2, "!mock tool_call=tool_search:#{discover} reply=private-answer -- private question")
    @bridge.lose_next_ack = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(private_update) }
    assert_equal private_update.fetch("update_id"), @state.read.fetch("pending_update").fetch("update").fetch("update_id")
    @runtime.consume(private_update)
    assert_empty @telegram.calls.select { |method, _params| method == "sendMessage" },
      "an ordinary direct reply must not start with a task receipt"
    private_id = current("101:0")
    private_chat = @workspace.conversation(private_id)
    first = completed_reply(private_chat)
    assert_equal 1, private_chat.events(limit: 100).count { |event| event.type == "input_accepted" }
    speaker_id = @state.read.fetch("speakers").fetch("101")
    actor = @client.profile.register_ingress_speaker(channel_key: "telegram:#{@bot.fetch("id")}", external_id: "101", display_name: "External Ada")
    assert_equal "ingress", actor.kind
    assert_equal speaker_id, actor.public_id
    assert_equal "External Ada", actor.display_name
    request = request_text(first)
    assert_includes request, "kind=\"ingress\" speaker=\"#{speaker_id}\""
    assert_includes request, marker
    refute_includes request, skill, "private skill metadata is deferred from the eager prompt"
    discovered = JSON.parse(successful_tool_output(first, "tool_search")).fetch("tools")
      .flat_map { |tool| tool.fetch("skills") }
    assert_includes discovered, { "name" => skill, "description" => skill, "callable" => "skill",
      "source" => "user", "executor_public_id" => nil }, "the private turn can discover its user's skill"
    await("private final delivery") { tick; @telegram.formal(101).length == 1 }
    assert_equal "Mock: private-answer", @telegram.formal(101).first.last.fetch(:text)
    replies = @telegram.calls.select do |method, params|
      method == "sendMessage" && params.dig(:reply_parameters, :message_id) == private_update.dig("message", "message_id")
    end
    assert_equal 1, replies.length,
      "the direct answer is the only message for an ordinary request"
    @runtime.consume(private_update)
    tick
    assert_equal 1, @telegram.formal(101).length
    assert_equal 1, private_chat.events(limit: 100).count { |event| event.type == "input_accepted" }

    assert_group_privacy(marker, skill)
    assert_supplementary_delivery(check_late_control: true)
  end

  def test_completed_task_id_stop_preserves_a_later_independent_request
    boot_runtime(allowed: [101])
    assert_supplementary_delivery(check_late_control: true, by_task_id: true)
  end

  def test_workspace_selection_preserves_original_work_across_chat_switch_and_daemon_restart
    boot_runtime(allowed: [101, 102])
    original_workspace = @workspace.public_id
    @runtime.consume(update(1, "/new", chat: -10, topic: 7))
    @runtime.consume(update(2, "/new", chat: -10, topic: 8))
    untouched_topic = current("-10:8")
    selected_workspace = nil
    original_conversation = nil

    assert_supplementary_delivery(answer_id: 100) do |conversation_id, question_id|
      original_conversation = conversation_id
      @runtime.consume(update(8, "/workspace create Project two"))
      selected_workspace = @state.read.fetch("routes").fetch("101:0").fetch("workspace_public_id")
      refute_equal original_workspace, selected_workspace
      created = @client.workspaces.fetch(selected_workspace)
      assert_equal "Project two", created.name
      assert_equal "private", created.access_mode
      assert created.dedicated
      refute_equal conversation_id, current("101:0")
      assert @state.read.fetch("routes").fetch("101:0").fetch("conversations").key?(conversation_id)
      assert_equal original_workspace, @daemon.status.fetch("workspace").fetch("public_id")

      @runtime.consume(update(9, "/workspace use #{selected_workspace}", chat: -10, topic: 7))
      assert_equal selected_workspace, @state.read.fetch("routes").fetch(telegram_route_key("-10:7")).fetch("workspace_public_id")
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
      assert @state.read.fetch("questions").key?(question_id), "the original question remains answerable"
      assert_equal original_workspace, @core.conversation(conversation_id).fetch("workspace_public_id")
      assert_equal untouched_topic, current("-10:8")
    end

    todos = CGI.escape(JSON.generate("todos" => [{ "content" => "Keep working in the original workspace", "status" => "in_progress" }]))
    child_todos = CGI.escape(JSON.generate("todos" => [{ "content" => "The waited child stays in its original workspace", "status" => "in_progress" }]))
    child_prompt = "!mock tool_call=todo_write:#{child_todos} reply=child-finished -- child work"
    spawn = CGI.escape(JSON.generate("prompt" => child_prompt, "label" => "workspace-child", "wait" => true))
    # The stateless mock counts the two earlier code/ask answers in history.
    script = "todo_write:#{todos},todo_write:#{todos},todo_write:#{todos}&spawn:#{spawn}"
    @core.say(original_conversation, "!mock tool_call=#{script} -- update the old task", model: MODEL)
    old_chat = @workspace.conversation(original_conversation)
    todo_turn = await("a new tool-using turn in the original workspace") do
      replies = old_chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      replies.last if replies.length == 3
    end
    assert_equal "Todo list updated: 1 item, 0 completed.", successful_tool_output(todo_turn, "todo_write")
    assert_includes old_chat.memory.read("conversation/todo.md").content, "Keep working in the original workspace"
    child = old_chat.children.items.find { |row| row.parent&.label == "workspace-child" }
    refute_nil child
    assert_includes @workspace.conversation(child.public_id).memory.read("conversation/todo.md").content,
      "The waited child stays in its original workspace"

    selected_chat = @client.workspace(selected_workspace).conversation(current("101:0"))
    @runtime.consume(update(101, "!mock reply=selected-workspace -- a new workspace question"))
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
    @core.say(original_conversation, "!mock tool_call=#{script} -- check the original runner", model: MODEL)
    recovered = await("the original runner works despite an unavailable default") do
      replies = old_chat.turns.list.items.select { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
      replies.last if replies.length == 4
    end
    assert_includes successful_tool_output(recovered, "bash"), "original-workspace-after-restart"

    @runtime.consume(update(102, "/workspace list"))
    assert_nil @state.read["pending_update"]
    @runtime.consume(update(103, "/workspace use #{original_workspace}"))
    assert_equal original_workspace, @state.read.fetch("routes").fetch("101:0").fetch("workspace_public_id")
    output, status = @daemon.cli("workspaces", "use", original_workspace)
    assert_predicate status, :success?, output
    reopened = @core.open_conversation.fetch("conversation").fetch("public_id")
    assert_equal original_workspace, @core.conversation(reopened).fetch("workspace_public_id")
    assert_empty @logs
  end

  def test_a_waited_child_question_remains_answerable_when_the_new_default_is_unavailable
    boot_runtime(allowed: [101])
    @runtime.consume(update(1, "/new"))
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
    todos = CGI.escape(JSON.generate("todos" => [{ "content" => "Answered in the original workspace", "status" => "in_progress" }]))
    child_prompt = "!mock tool_call=ask:#{question},todo_write:#{todos} reply=child-finished -- child question"
    spawn = CGI.escape(JSON.generate("prompt" => child_prompt, "label" => "asking-child", "wait" => true))
    @core.say(original_id, "!mock tool_call=spawn:#{spawn} reply=parent-finished -- waited child", model: MODEL)
    question_id, pending = await("the unfollowed child's question in Telegram") do
      tick
      @state.read.fetch("questions").find { |_id, row| row.fetch("kind") == "ask" && !row["resolved"] }
    end
    assert_equal original_id, pending.fetch("conversation_id")
    assert_equal @workspace.public_id, pending.fetch("workspace_public_id")
    @runtime.consume(update(2, "/answer #{question_id} Yes, continue."))
    assert @state.read.fetch("questions").fetch(question_id).fetch("resolved")
    assert_equal "Mock: parent-finished", completed_reply(original).active_variant.content
    child = original.children.items.find { |row| row.parent&.label == "asking-child" }
    refute_nil child
    assert_includes @workspace.conversation(child.public_id).memory.read("conversation/todo.md").content,
      "Answered in the original workspace"
    assert_equal "error", @daemon.status.fetch("workspace").fetch("state")
    assert_empty @logs
  end

  def test_another_surface_resolves_a_question_and_archive_restore_restarts_following
    boot_runtime(allowed: [101])
    arguments = CGI.escape(JSON.generate("prompt" => "Which database should I use?"))
    @runtime.consume(update(1, "!mock tool_call=ask tool_args=#{arguments} reply=answered-elsewhere -- choose a database"))
    conversation_id = current("101:0")
    chat = @workspace.conversation(conversation_id)
    question_id, question = await("a delivered Telegram question") do
      tick
      @state.read.fetch("questions").find { |_id, row| Array(row["message_ids"]).any? }
    end
    reply_message = @telegram.calls.find { |method, params| method == "sendMessage" && params[:text].include?(question_id) }.last
    assert_bound_console(conversation_id)
    @core.answer(question.fetch("run_public_id"), question.fetch("task_key"), "Postgres",
      workspace_public_id: question.fetch("workspace_public_id"))
    completed_reply(chat)
    await("the reply after another surface answered") { tick; @telegram.formal(101).length == 1 }
    before = chat.events(limit: 100).count { |event| event.type == "input_accepted" }
    stale = update(2, "SQLite")
    stale.fetch("message")["reply_to_message"] = {
      "message_id" => question.fetch("message_ids").first, "from" => @bot.merge("is_bot" => true),
      "text" => reply_message.fetch(:text),
    }
    @runtime.consume(stale)
    assert_equal before, chat.events(limit: 100).count { |event| event.type == "input_accepted" },
      "answering an expired Telegram question must not become an ordinary new turn"

    alternate = @core.create_workspace(name: "Archive recovery workspace")
    output, status = @daemon.cli("workspaces", "use", alternate.fetch("public_id"))
    assert_predicate status, :success?, output
    @runtime.close
    @browser.close
    @browser = nil
    @daemon.stop
    @daemon.start
    await("the new daemon default after restart") do
      @daemon.status.dig("workspace", "public_id") == alternate.fetch("public_id")
    end
    connect_bridge(alternate.fetch("public_id"))
    boot_runtime(allowed: [101])

    # Leave this answer unread by Telegram until archive has removed the local
    # host binding. A fixed-workspace adapter fixture would conceal the bug.
    @core.say(conversation_id, "!mock reply=before-archive -- preserve readable history", mode: "queue", wait: false)
    await("a completed answer before archive") do
      chat.turns.list.items.any? { |row| row.status == "completed" && row.active_variant.content == "Mock: before-archive" }
    end
    hosts = Rho::HostStore.new(@home.host_cache_path(@client.profile.fetch.member.public_id))
    refute_nil hosts.find(conversation_id), "the followed conversation has its original-workspace binding"
    chat.archive
    await("archive removes the local follower") do
      @daemon.control(:get, "/followers").fetch("followers").none? { |row| row.fetch("public_id") == conversation_id }
    end
    assert_nil hosts.find(conversation_id), "archive really removed the local original-workspace binding"
    assert_predicate chat.fetch, :archived?
    await("readable archived history still reaches Telegram in its original workspace") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: before-archive" }
    end
    tracker = @state.read.fetch("routes").fetch("101:0").fetch("conversations").fetch(conversation_id)
    assert_equal @workspace.public_id, tracker.fetch("workspace_public_id")
    assert_equal alternate.fetch("public_id"), @daemon.status.dig("workspace", "public_id")

    chat.unarchive
    @core.attach(conversation_id, host_type: "conversation", workspace_public_id: @workspace.public_id)
    @core.say(conversation_id, "!mock reply=after-restore -- a message from another surface", mode: "queue", wait: false,
      workspace_public_id: @workspace.public_id)
    await("the restored follower reads the new answer") do
      row = @daemon.control(:get, "/followers").fetch("followers").find { |item| item.fetch("public_id") == conversation_id }
      row && row["text"] == "Mock: after-restore"
    end
    await("the shared conversation mirrors the new answer to Telegram") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: after-restore" }
    end
    assert_equal conversation_id, current("101:0")
    @runtime.consume(update(3, "/new"))
    refute_equal conversation_id, current("101:0")
    open_console(conversation_id)
    assert @browser.page.has_field?("Message", disabled: false, wait: E2E::RhoDaemon::WATCH_TIMEOUT),
      "the old conversation becomes editable when Telegram binds a new one"
    assert @browser.page.has_no_text?("Continue in the original channel.")
    assert_empty @logs
  end

  def test_a_rate_limited_answer_is_not_sent_after_another_surface_replaces_its_variant
    boot_runtime(allowed: [101])
    @runtime.consume(update(1, "!mock reply=obsolete-answer -- answer to revise"))
    conversation_id = current("101:0")
    chat = @workspace.conversation(conversation_id)
    original = completed_reply(chat)
    @telegram.refuse_next_formal = true
    tick
    assert_empty @telegram.formal(101)
    assert @state.read.fetch("deliveries").values.any? { |row| row["status"] == "pending" && row["conversation_id"] == conversation_id }

    edited = chat.turns.edit(original.public_id, text: "The revised answer from another surface.")
    refute_equal original.active_variant.public_id, edited.public_id
    @core.say(conversation_id, "!mock reply=current-answer -- continue after the edit", mode: "queue", wait: false)
    await("only a current answer is delivered after the throttle") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: current-answer" }
    end
    refute @telegram.formal(101).any? { |_method, params| params[:text].include?("obsolete-answer") }
    assert_empty @logs
  end
end
