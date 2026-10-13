require_relative "support/rho_telegram_case"

# Admission, batching and supplementary delivery cross the real daemon and Nexus.
class RhoTelegramTest < E2E::RhoTelegramCase
  def test_a_configured_message_burst_survives_adapter_restart_as_one_input
    assert_equal 2, @core.telegram_settings(agent_public_id: bot_id_for("101:0")).dig("configuration", "input_debounce_seconds")
    configured = @core.configure_telegram({ "input_debounce_seconds" => 10 }, agent_public_id: bot_id_for("101:0"))
    assert configured.fetch("saved")
    assert configured.fetch("applied")
    delay = @core.telegram_settings(agent_public_id: bot_id_for("101:0")).dig("configuration", "input_debounce_seconds")
    assert_equal 10, delay
    boot_runtime(allowed: [101], input_debounce_seconds: delay)
    first = update(1, "Please write a report")
    second = update(2, "!mock reply=batched-correction -- Actually, make it a short note")
    @runtime.consume(first)
    chat = @workspace.conversation(current("101:0"))
    assert_empty chat.inputs.list.items
    assert_empty chat.turns.list.items
    sleep 1
    @runtime.consume(second)
    boot_runtime(allowed: [101], input_debounce_seconds: delay)
    tick
    assert_empty chat.inputs.list.items
    assert_empty chat.turns.list.items
    answer = await("the restarted adapter to admit the assembled burst") do
      tick
      chat.turns.list.items.find { |turn| turn.kind == "direct_reply" && turn.status == "completed" }
    end
    material = request_text(answer)
    assert_includes material, first.dig("message", "text")
    assert_includes material, second.dig("message", "text")
    assert_operator material.index("Please write a report"), :<, material.index("Actually, make it a short note")
    assert_equal 1, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
    assert_equal "Mock: batched-correction", answer.active_variant.content
    await("one Telegram answer for the whole burst") { tick; @telegram.formal(101).length == 1 }
    @core.configure_telegram({ "input_debounce_seconds" => 0 }, agent_public_id: bot_id_for("101:0"))
    delay = @core.telegram_settings(agent_public_id: bot_id_for("101:0")).dig("configuration", "input_debounce_seconds")
    assert_equal 0, delay
    boot_runtime(allowed: [101], input_debounce_seconds: delay)
    @runtime.consume(update(3, "!mock reply=immediate-answer -- send without a timer pass"))
    assert_empty @state.read.fetch("pending_inputs")
    assert_equal 2, chat.events(limit: 100).count { |event| event.type == "input_accepted" }
    await("the zero-delay answer reaches Telegram") do
      tick
      @telegram.formal(101).any? { |_method, params| params[:text] == "Mock: immediate-answer" }
    end
    assert_empty @logs
  end

  def test_allowed_speakers_group_privacy_replay_and_supplementary_delivery
    boot_runtime(allowed: [])
    receive(update(1, "Do not admit this stranger", user: 999, chat: 999))
    assert_empty @state.read.fetch("speakers")
    assert_empty @state.read.fetch("routes")
    assert_empty @core.conversations.fetch("conversations")

    marker = "private-note-#{SecureRandom.hex(6)}"
    skill = "private-skill-#{SecureRandom.hex(6)}"
    @agent_memory << @client.profile.memory.write("agent/#{marker}.md", marker,
      expected_public_id: nil, expected_lock_version: nil)
    @agent_memory << @client.profile.memory.write("agent/skills/#{skill}", "Secret skill instructions.", description: skill,
      expected_public_id: nil, expected_lock_version: nil)
    human_marker = "human-note-#{SecureRandom.hex(6)}"
    human_skill = "human-skill-#{SecureRandom.hex(6)}"
    @memory << @human.profile.memory.write("user/#{human_marker}.md", human_marker,
      expected_public_id: nil, expected_lock_version: nil)
    @memory << @human.profile.memory.write("user/skills/#{human_skill}", "Human skill instructions.", description: human_skill,
      expected_public_id: nil, expected_lock_version: nil)
    boot_runtime(allowed: [101, 102])
    discover = CGI.escape(JSON.generate("query" => "skill"))
    private_update = update(2, "!mock tool_call=tool_search:#{discover} reply=private-answer -- private question")
    @bridge.lose_next_ack = true
    receive(private_update)
    assert pending_input(private_update).fetch("submission")
    assert_nil @state.read["pending_update"], "the source is durable before Telegram advances its offset"
    assert_equal "Rho::ConnectionError", @logs.pop.last.fetch(:reason)
    receive(private_update)
    assert_empty @telegram.calls.select { |method, params| method == "sendMessage" && params[:parse_mode] != "HTML" &&
      params.dig(:reply_parameters, :message_id) == private_update.dig("message", "message_id") },
      "an ordinary direct reply must not start with a task receipt"
    private_id = current("101:0")
    private_chat = @workspace.conversation(private_id)
    first = completed_reply(private_chat)
    assert_equal 1, private_chat.events(limit: 100).count { |event| event.type == "input_accepted" }
    speaker_id = @state.read.fetch("speakers").fetch("101")
    actor = @client.profile.register_ingress_speaker(channel_key: "rho:#{@client.profile.fetch.member.public_id}",
      external_id: "owner", display_name: "Owner")
    assert_equal "ingress", actor.kind
    assert_equal speaker_id, actor.public_id
    assert_equal "Owner", actor.display_name
    request = request_text(first)
    assert_includes request, "kind=\"ingress\" speaker=\"#{speaker_id}\""
    refute_includes request, marker, "the Main Agent memory does not become this Bot identity's memory"
    refute_includes request, human_marker, "the owner turn does not implicitly bind Human memory"
    refute_includes request, skill, "private skill metadata is deferred from the eager prompt"
    discovered = JSON.parse(successful_tool_output(first, "tool_search")).fetch("tools")
      .flat_map { |tool| tool.fetch("skills") }
    refute discovered.any? { |entry| entry.fetch("name") == skill }, "the Bot cannot discover another identity's Agent skills"
    refute discovered.any? { |entry| entry.fetch("name") == human_skill }, "Human skills require an explicit binding"
    await("private final delivery") { tick; @telegram.formal(101).length == 1 }
    assert_equal "Mock: private-answer", @telegram.formal(101).first.last.fetch(:text)
    replies = @telegram.calls.select do |method, params|
      method == "sendMessage" && params.dig(:reply_parameters, :message_id) == private_update.dig("message", "message_id")
    end
    assert_equal 1, replies.length,
      "the direct answer is the only message for an ordinary request"
    receive(private_update)
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
end
