require_relative "support/rho_telegram_case"

# Other surfaces can complete work while Telegram preserves its original delivery.
class RhoTelegramDeliveryTest < E2E::RhoTelegramCase
  def test_another_surface_resolves_a_question_and_old_bot_history_stays_read_only
    boot_runtime(allowed: [101])
    arguments = CGI.escape(JSON.generate("prompt" => "Which database should I use?"))
    receive(update(1, "!mock tool_call=ask tool_args=#{arguments} reply=answered-elsewhere -- choose a database"))
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
    receive(stale)
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

    # Leave this answer unread by Telegram until the follower consumes archive.
    # Accepted work and its delivery keep the original workspace and host binding.
    @core.say(conversation_id, "!mock reply=before-archive -- preserve readable history", mode: "queue", wait: false)
    await("a completed answer before archive") do
      chat.turns.list.items.any? { |row| row.status == "completed" && row.active_variant.content == "Mock: before-archive" }
    end
    hosts = Rho::HostStore.new(@home.host_cache_path(@client.profile.fetch.member.public_id))
    refute_nil hosts.find(conversation_id), "the followed conversation has its original-workspace binding"
    chat.archive
    archive_sequence = chat.events.watermark
    await("the original follower reads archive") do
      row = @daemon.control(:get, "/followers").fetch("followers").find { |item| item.fetch("public_id") == conversation_id }
      row && row.fetch("sequence") >= archive_sequence
    end
    refute_nil hosts.find(conversation_id), "archive preserves the original-workspace binding for accepted work"
    assert_predicate chat.fetch, :archived?
    await("readable archived history still reaches Telegram in its original workspace") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: before-archive" }
    end
    tracker = state_for("101:0").read.fetch("routes").fetch(telegram_route_key("101:0")).fetch("conversations").fetch(conversation_id)
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
    receive(update(3, "/new"))
    refute_equal conversation_id, current("101:0")
    open_console(conversation_id)
    assert @browser.page.has_field?("Message", disabled: true, wait: E2E::RhoDaemon::WATCH_TIMEOUT),
      "historical Bot provenance keeps the old conversation read-only after /new"
    assert @browser.page.has_text?("Telegram · Chat 101 — Continue in the original channel. This page is read-only. Stop remains available.")
    assert_empty @logs
  end

  def test_a_rate_limited_answer_is_not_sent_after_another_surface_replaces_its_variant
    boot_runtime(allowed: [101])
    receive(update(1, "!mock reply=obsolete-answer -- answer to revise"))
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
