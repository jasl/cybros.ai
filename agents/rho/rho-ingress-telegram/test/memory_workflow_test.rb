require "support/runtime"
require "support/participation"

class TelegramMemoryWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def test_group_members_share_the_bot_conversation_and_keep_distinct_speakers
    receive(mention(1))
    receive(mention(2, user: 2))

    assert_equal ["conversation-1"], @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }.uniq
    assert_equal %w[speaker-1 speaker-2], @bridge.inputs.values.map { |row| row.fetch(:speaker) }
    assert_empty @bridge.memory_anchors
    assert @bridge.memory_bindings.values.all?(&:nil?), "The adapter must not bind a second memory graph"
    refute_path_exists File.join(@directory, "telegram", "state.json")
  end

  def test_new_and_restart_keep_speakers_and_use_core_for_the_next_conversation
    receive(mention(1, user: 2))
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    receive(telegram_message(2, "/new", chat: -10, topic: 4))
    receive(mention(3, user: 2))

    assert_equal %w[conversation-1 conversation-2], @bridge.inputs.values.map { |row| row.fetch(:conversation_id) }
    assert_equal %w[speaker-2 speaker-2], @bridge.inputs.values.map { |row| row.fetch(:speaker) }
    assert_empty @bridge.memory_anchors
    assert @bridge.memory_bindings.values.all?(&:nil?)
  end

  def test_the_current_member_is_supplied_for_every_memory_read_and_write
    calls = []
    @bridge.define_singleton_method(:memory) do |id, action:, workspace_public_id:, speaker_public_id:|
      calls << [id, action.verb, workspace_public_id, speaker_public_id]
      "Memory result"
    end
    receive(mention(1))
    receive(telegram_message(2, "/memory ls", user: 2, chat: -10, topic: 4))
    receive(telegram_message(3, "/memory write speaker/notes.md My fact", user: 2, chat: -10, topic: 4))
    receive(telegram_message(4, "/memory ls", chat: -10, topic: 4))

    assert_equal [["conversation-1", "ls", "workspace-home", "speaker-2"],
      ["conversation-1", "write", "workspace-home", "speaker-2"],
      ["conversation-1", "ls", "workspace-home", "speaker-1"]], calls
  end

  def test_existing_member_input_never_rebinds_the_shared_conversation_to_that_person
    receive(mention(1, user: 2))
    receive(mention(2))
    receive(mention(3, user: 2))

    assert_equal 1, @bridge.opened.length
    assert_equal %w[speaker-2 speaker-1 speaker-2], @bridge.inputs.values.map { |row| row.fetch(:speaker) }
    assert @bridge.memory_bindings.values.all?(&:nil?)
  end

  def test_memory_write_keeps_its_workspace_speaker_and_durable_control_receipt
    calls = []
    @bridge.define_singleton_method(:memory) do |id, action:, workspace_public_id:, speaker_public_id:|
      calls << [id, action.verb, action.fields, workspace_public_id, speaker_public_id]
      "Write completed: conversation/notes.md"
    end
    receive(mention(1))
    command = telegram_message(2, "/memory write conversation/notes.md Team fact", chat: -10, topic: 4)
    receive(command)
    receive(command)

    assert_equal [["conversation-1", "write", { path: "conversation/notes.md", content: "Team fact" }, "workspace-home", "speaker-1"]], calls
    assert_includes @state.read.fetch("deliveries").fetch("control:telegram:#{BOT}:#{CONNECTION}:42:2:reply").fetch("text"), "Write completed"
  end

  private

    def mention(id, user: 1)
      telegram_message(id, "@rho_bot Help", user: user, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    end
end

class TelegramParticipationMemoryTest < Minitest::Test
  include TelegramParticipationSupport

  def test_active_participation_reads_memory_as_the_observed_speaker_in_the_same_conversation
    reads = []
    @bridge.define_singleton_method(:participation_memory) do |id, model:, workspace_public_id:, speaker_public_id:|
      reads << [id, model, workspace_public_id, speaker_public_id]
      "Shared database fact: release is blue"
    end
    enable_participation
    group_message(3, "Which release color did we choose?", user: 2)
    advance(5)

    assert_equal [["conversation-1", "vendor/default", "workspace-home", "speaker-2"]], reads
    assert_includes @bridge.participation_starts.fetch(0).fetch(:prompt), "Shared database fact: release is blue"
  end

  def test_restart_uses_the_frozen_observed_speaker_before_any_new_message
    enable_participation
    group_message(3, "Which release color did we choose?", user: 2)
    calls = []
    @bridge.define_singleton_method(:participation_memory) do |id, **fields|
      calls << [id, fields.fetch(:speaker_public_id)]
      "Shared fact only"
    end
    @runtime = runtime
    advance(5)

    assert_equal [["conversation-1", "speaker-2"]], calls
    assert_empty @bridge.memory_anchors
    assert_includes @bridge.participation_starts.fetch(0).fetch(:prompt), "Shared fact only"
  end
end
