require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

class MemoryCollectionDefaultRaceTest < ActiveJob::TestCase
  include LockOrderTestHelper
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @agent = users(:agent)
    @human = users(:member)
    @saved_declaration = @agent.attributes.slice(*User::Configurable::ATTRIBUTES.map(&:to_s))
    declare_tools!(@agent, tools: [Nexus::ToolRegistry.function_definition("memory_read")])
    @conversation = Conversations::Create.call(Conversations::Create::Command.new(workspace: workspaces(:shared),
      creating_user: @human, answering_user_public_id: @agent.public_id,
      title: nil, metadata: nil, billing_subject: nil)).value
    input = post_input!(@conversation, acting_user: @human, text: "first use", kind: "direct_reply",
      provider_id: "dev", model_ref: "mock-text")
    @speaker = input.speaker
  end

  teardown do
    begin
      release_row_lock(@held) if @held
    ensure
      stop_database_call(@call) if @call
      [@child, @conversation].compact.each do |conversation|
        next unless Conversation.exists?(conversation.id)

        run_ids = conversation.hosted_runs.pluck(:id)
        Conversations::Turns::Cancel.stop_now(conversation.reload)
        Conversations::Turns::Converge.call(conversation_id: conversation.id)
        Conversations::Tombstone.call(conversation: conversation.reload)
        if Conversation.exists?(conversation.id)
          conversation.reload.update!(tombstoned_at: (Conversation::RETENTION_PERIOD + 1.day).ago)
          Conversations::Reap.call(batch: 20)
        end
        Run.where(id: run_ids).each { |run| run.with_lock { Runs::Reap.destroy_aggregate(run) } }
      end
      if @agent && @speaker
        @agent.with_lock do
          @agent.memory_collections.where(speaker: @speaker).each do |collection|
            MemoryCollections::Drain.collection(id: collection.id, budget: 65)
          end
        end
      end
      @agent&.update_columns(@saved_declaration) if @saved_declaration
    end
  end

  test "materialization releases the Conversation before first-use User preparation so a concurrent fork can finish" do
    @held = hold_row_lock(User, @agent.id, before_commit: ->(_agent) {
      result = Conversations::Fork.call(Conversations::Fork::Command.new(conversation: Conversation.find(@conversation.id),
        acting_user: @human, turn_public_id: nil, variant_public_id: nil, title: nil, side: true))
      assert_predicate result, :accepted?, result.outcome.to_s
      @child = result.value
    })
    @call = start_database_call { Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id) }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_predicate result, :accepted?, result.outcome.to_s
    assert @child.persisted?
    assert_equal 1, @agent.memory_collections.where(speaker: @speaker).count
    capture = result.value.active_variant.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }.fetch("capture")
    assert_equal MemoryCollection.default_for(@agent, speaker: @speaker).public_id, capture.fetch("collection_public_id")
  end

  test "a concurrent first default deleted before acceptance stays the same tombstone" do
    winner = nil
    @held = hold_row_lock(User, @agent.id, before_commit: ->(agent) {
      winner = MemoryCollection.default_for(agent, speaker: @speaker)
      winner.tombstone
    })
    @call = start_database_call { Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id) }
    wait_until_transitively_blocked_by(@held.pid, @call.pid)
    release_holder
    result = finish_database_call(@call)
    @call = nil
    assert_predicate result, :accepted?, result.outcome.to_s
    assert_equal 1, @agent.memory_collections.where(speaker: @speaker).count
    capture = result.value.active_variant.memory_context.fetch("bindings").find { |entry| entry.fetch("name") == "speaker" }.fetch("capture")
    assert_equal winner.public_id, capture.fetch("collection_public_id")
    assert_predicate winner.reload, :deleted?
    assert_nil result.value.active_variant.run.stopped_at
  end

  private

    def release_holder
      held, @held = @held, nil
      release_row_lock(held)
    end
end
