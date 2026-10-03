require "support/runtime"
require "support/participation"

class TelegramMemoryWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_group_requesters_share_one_database_anchor_with_distinct_write_access
    @runtime.consume(mention(1))
    @runtime.consume(mention(2, user: 2))
    owner, member = %w[conversation-1 conversation-2].map { |id| @bridge.memory_bindings.fetch(id).fetch("bindings") }
    assert_equal %w[conversation group], owner.map { |row| row.fetch("name") }
    assert_equal %w[conversation group], member.map { |row| row.fetch("name") }
    assert_equal owner.last.fetch("conversation_public_id"), member.last.fetch("conversation_public_id")
    assert_equal "read_write", owner.last.fetch("access")
    assert_equal "read", member.last.fetch("access")
    assert_equal 1, @bridge.memory_anchors.length
    refute_path_exists File.join(@directory, "telegram", "state.json")
  end

  def test_new_task_and_restart_keep_group_memory_while_topics_have_separate_anchors
    @runtime.consume(mention(1))
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    @runtime.consume(telegram_message(2, "/new", chat: -10, topic: 4))
    @runtime.consume(mention(3, topic: 5))
    anchors = %w[conversation-1 conversation-2 conversation-3].map { |id| @bridge.memory_bindings.fetch(id).fetch("bindings").last.fetch("conversation_public_id") }
    assert_equal anchors.first, anchors[1]
    refute_equal anchors.first, anchors.last
    assert_equal 2, @bridge.memory_anchors.length
  end

  def test_owner_private_chat_keeps_default_memory_and_external_person_has_no_owner_scope
    @runtime.consume(telegram_message(1, "Owner request"))
    @runtime.consume(telegram_message(2, "External person's request", user: 2))
    @runtime.consume(telegram_message(3, "/new", user: 2))
    assert_nil @bridge.memory_bindings.fetch("conversation-1")
    first, second = %w[conversation-2 conversation-3].map { |id| @bridge.memory_bindings.fetch(id).fetch("bindings") }
    assert_equal %w[conversation person], first.map { |row| row.fetch("name") }
    assert_equal first.last.fetch("conversation_public_id"), second.last.fetch("conversation_public_id")
    refute first.any? { |row| %w[user workspace].include?(row.fetch("scope")) }
  end

  def test_existing_nonowner_private_conversation_gets_binding_before_its_next_input
    @runtime.consume(telegram_message(1, "Old request", user: 2))
    @state.change { |document| document.fetch("routes").fetch("2:0").fetch("conversations").fetch("conversation-1").delete("memory_bound") }
    @bridge.memory_bindings.clear
    @runtime.consume(telegram_message(2, "Continue", user: 2))
    assert_equal %w[conversation person], @bridge.memory_bindings.fetch("conversation-1").fetch("bindings").map { |row| row.fetch("name") }
    assert_equal true, @bridge.inputs.fetch("telegram:42:2:input").fetch(:isolated)
  end

  def test_memory_command_carries_the_conversation_workspace_and_uses_control_receipts
    calls = []
    @bridge.define_singleton_method(:memory) do |id, action:, workspace_public_id:|
      calls << [id, action.verb, action.fields, workspace_public_id]
      "Write completed: group/notes.md"
    end
    @runtime.consume(mention(1))
    command = telegram_message(2, "/memory write group/notes.md Team fact", chat: -10, topic: 4)
    @runtime.consume(command)
    @runtime.consume(command)
    assert_equal [["conversation-1", "write", { path: "group/notes.md", content: "Team fact" }, "workspace-home"]], calls
    assert_includes @state.read.fetch("deliveries").fetch("control:2").fetch("text"), "Write completed"
  end

  def test_legacy_nonowner_side_question_uses_the_isolated_answerer
    @runtime.consume(telegram_message(1, "Old request", user: 2))
    @state.change { |document| document.fetch("routes").fetch("2:0").fetch("conversations").fetch("conversation-1").delete("memory_bound") }
    @bridge.memory_bindings.clear
    @runtime.consume(telegram_message(2, "/btw Explain that term", user: 2))
    input = @bridge.inputs.fetch("telegram:42:2:side-input")
    assert_equal true, input.fetch(:isolated)
    assert_equal [], input.fetch(:tool_names)
    assert_equal %w[conversation person], @bridge.memory_bindings.fetch("conversation-1").fetch("bindings").map { |row| row.fetch("name") }
  end

  def test_followup_to_a_legacy_side_task_also_migrates_its_memory_roots
    @runtime.consume(telegram_message(1, "/btw Explain that term", user: 2))
    @state.change { |document| document.fetch("routes").fetch("2:0").fetch("conversations").fetch("side-1").delete("memory_bound") }
    @runtime.consume(telegram_message(2, "More detail", user: 2, reply_to: 1, reply_user: 2))
    input = @bridge.inputs.fetch("telegram:42:2:input")
    assert_equal "side-1", input.fetch(:conversation_id)
    assert_equal %w[conversation person], @bridge.memory_bindings.fetch("side-1").fetch("bindings").map { |row| row.fetch("name") }
  end

  private

    def mention(id, user: 1, topic: 4)
      telegram_message(id, "@rho_bot Help", user: user, chat: -10, topic: topic,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end
end

class TelegramParticipationMemoryTest < Minitest::Test
  include TelegramParticipationSupport

  def test_active_participation_uses_the_same_database_memory_selection
    reads = []
    @bridge.define_singleton_method(:participation_memory) do |id, model:, workspace_public_id:|
      reads << [id, model, workspace_public_id]
      "Shared database fact: release is blue"
    end
    enable_participation
    group_message(3, "Which release color did we choose?", user: 2)
    advance(5)
    assert_equal [["memory-1", "vendor/default", "workspace-home"]], reads
    assert_includes @bridge.participation_starts.fetch(0).fetch(:prompt), "Shared database fact: release is blue"
  end

  def test_restart_migrates_old_observation_memory_before_any_new_message
    enable_participation
    group_message(3, "Which release color did we choose?", user: 2)
    @state.change { |document| document.fetch("rooms").fetch("-10:4").delete("memory_conversations") }
    @bridge.memory_bindings.clear
    @bridge.define_singleton_method(:participation_memory) do |id, **|
      raise "Missing observation binding" unless @memory_bindings[id] == Rho::IngressTelegram::MemoryBridge::LOCAL_MEMORY

      "Shared fact only"
    end
    @runtime = runtime
    advance(5)
    assert_equal Rho::IngressTelegram::MemoryBridge::LOCAL_MEMORY, @bridge.memory_bindings.fetch("memory-1")
    assert_includes @bridge.participation_starts.fetch(0).fetch(:prompt), "Shared fact only"
  end
end
