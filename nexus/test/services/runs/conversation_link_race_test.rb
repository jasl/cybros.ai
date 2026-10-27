require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class Runs::ConversationLinkRaceTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include RowLockTestHelper
  include LockOrderTestHelper

  self.use_transactional_tests = false

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    declare_tools!(@agent, tools: [Nexus::Tools::SEND], default_model: "dev/mock-text")
    @source, @target = 2.times.map do
      Conversation.create!(workspace: @workspace, creating_user: users(:member), answering_user: @agent)
    end
    @link = Conversations::Links::Create.call(conversation: @source, agent: @agent,
      peer_conversation: @target, peer_agent: @agent, acting_user: users(:member)).value
    _turn, @run = materialize_loop_reply!(@source, agent: @agent)
    schedule_loop!(@run)
    apply_via(loop_attempt(@run), sse_success("sending", tool_calls: [
      { id: "race_message", name: "send", arguments: { link_public_id: @link.public_id, message: "Consume me" }.to_json },
    ]))
    Runs::ConvergeTerminalSteps.call
    clear_enqueued_jobs
    perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
      Runs::ScheduleReady.call(run_id: @run.id)
    end
    @input_id = @target.inputs.sole.public_id
    # Default Memory creation is preparation, outside the consumption transaction.
    input = @target.inputs.sole
    MemoryDocuments::Context.new(workspace: @workspace, conversation: @target,
      principal: input.processing_user, configuration: input.execution_memory_context,
      agent: input.execution_agent, execution: true).prepare_defaults
  end

  teardown do
    clear_enqueued_jobs
    [@target, @source].compact.each { |conversation| conversation.inputs.destroy_all }
    @link&.destroy!
    [@target, @source].compact.each do |conversation|
      ConversationCommandReceipt.where(host: conversation).delete_all
      conversation.hosted_runs.each do |run|
        UsageRecord.where(model_invocation_public_id: run.model_invocations.select(:public_id)).delete_all
        Runs::Reap.destroy_aggregate(run)
      end
      ModelUsageSummary.where(subject_kind: "conversation", subject_id: conversation.id).delete_all
      destroy_memory_owner!(conversation.reload)
    end
  end

  test "close commits before a waiting consumer and no execution is born" do
    held = hold_row_lock(ConversationLink, @link.id, before_commit: ->(link) { link.close })
    consumer = start_database_call { Conversations::Inputs::ApplyNext.call(conversation_id: @target.id) }
    wait_until_transitively_blocked_by(held.pid, consumer.pid)
    release_row_lock(held)
    held = nil
    assert finish_database_call(consumer).accepted?
    consumer = nil
    assert @link.reload.closed?
    refute Input.exists?(public_id: @input_id)
    refute @target.turns.exists?(input_public_id: @input_id)
  ensure
    release_row_lock(held) if held
    stop_database_call(consumer) if consumer
  end

  test "consumer holds the link through binding so close waits then preserves the execution" do
    held = hold_row_lock(Run, @run.id)
    consumer = start_database_call { Conversations::Inputs::ApplyNext.call(conversation_id: @target.id) }
    wait_until_transitively_blocked_by(held.pid, consumer.pid)
    closer = start_database_call { ConversationLink.find(@link.id).close }
    wait_until_transitively_blocked_by(consumer.pid, closer.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(consumer)
    consumer = nil
    assert result.accepted?, result.outcome.inspect
    finish_database_call(closer)
    closer = nil
    assert @link.reload.closed?
    worker = @target.turns.find_by!(input_public_id: @input_id).active_variant.run
    refute Runs::SourceWork.execution_stopped?(worker)
    assert_equal @agent, worker.creating_user
  ensure
    release_row_lock(held) if held
    stop_database_call(consumer) if consumer
    stop_database_call(closer) if closer
  end

  test "consumption follows the production lock ladder" do
    assert_ladder_order("linked queue consumption") do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @target.id)
      assert result.accepted?, result.outcome.inspect
    end
  end

  test "close wins before a strict steer boundary and the sealed request excludes its words" do
    strict_steer
    held = hold_row_lock(ConversationLink, @link.id, before_commit: ->(link) { link.close })
    consumer = start_database_call { Runs::ScheduleReady.call(run_id: @target_run.id) }
    wait_until_transitively_blocked_by(held.pid, consumer.pid)
    release_row_lock(held)
    held = nil
    finish_database_call(consumer)
    consumer = nil
    refute Input.exists?(@strict.id)
    refute_includes request_text, "strict correction"
    assert_empty @target.event_items.where(item_type: "input_materialized")
      .select { |event| event.payload["input_public_id"] == @strict.public_id }
  ensure
    release_row_lock(held) if held
    stop_database_call(consumer) if consumer
  end

  test "strict steer consumption holds its link until the model request commits" do
    strict_steer
    held = hold_row_lock(Run, @run.id)
    consumer = start_database_call { Runs::ScheduleReady.call(run_id: @target_run.id) }
    wait_until_transitively_blocked_by(held.pid, consumer.pid)
    closer = start_database_call { ConversationLink.find(@link.id).close }
    wait_until_transitively_blocked_by(consumer.pid, closer.pid)
    release_row_lock(held)
    held = nil
    finish_database_call(consumer)
    consumer = nil
    finish_database_call(closer)
    closer = nil
    assert_includes request_text, "strict correction"
    refute Input.exists?(@strict.id)
    assert @link.reload.closed?
    refute @target_run.reload.stopped?
  ensure
    release_row_lock(held) if held
    stop_database_call(consumer) if consumer
    stop_database_call(closer) if closer
  end

  test "source Stop wins before strict steer consumption and overrides queue fallback" do
    strict_steer(on_target_end: "queue")
    held = hold_row_lock(Run, @run.id, before_commit: ->(run) { Runs::Stop.cancel_locked(run) })
    consumer = start_database_call { Runs::ScheduleReady.call(run_id: @target_run.id) }
    wait_until_transitively_blocked_by(held.pid, consumer.pid)
    release_row_lock(held)
    held = nil
    finish_database_call(consumer)
    consumer = nil
    refute Input.exists?(@strict.id)
    refute_includes request_text, "strict correction"
  ensure
    release_row_lock(held) if held
    stop_database_call(consumer) if consumer
  end

  test "linked strict steer consumption follows the lock ladder" do
    strict_steer
    assert_ladder_order("linked strict steer consumption") do
      Runs::ScheduleReady.call(run_id: @target_run.id)
    end
    assert_includes request_text, "strict correction"
  end

  private

    def strict_steer(on_target_end: nil)
      @target.inputs.destroy_all
      _turn, @target_run = materialize_loop_reply!(@target, agent: @agent)
      accepted = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
        host: @target, acting_user: @agent, kind: "direct_reply", entries: [{ "text" => "strict correction" }],
        delivery_mode: "steer", expected_steering_run_public_id: @target_run.public_id, on_target_end: on_target_end,
        sender_conversation_public_id: @source.public_id, run_public_id: @run.public_id,
        communication_kind: "message", conversation_link: @link, answering_user_public_id: @agent.public_id))
      assert accepted.accepted?, accepted.outcome.inspect
      @strict = accepted.value
    end

    def request_text
      sealed_request_entries(@target_run.tasks.find_by!(node_key: "r1").selected_model_invocation).to_json
    end
end
