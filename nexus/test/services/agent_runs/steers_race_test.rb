require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The drain against the door, on committed rows with real PostgreSQL lock waits: on a conversation
# host the door holds conversation → input row and the drain holds loop → input row, so the row lock
# is the only thing between them, and either order must end without a torn state. The loop door's
# same-key race rides the hosted receipt's unique index.
class AgentRuns::SteersRaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  self.use_transactional_tests = false

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human)
    @seam = create_run_backed_turn(conversation: @conversation, acting_user: @human)
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
      agent_run: @seam.agent_run, steps: [model("only", "prompt" => "reply")]
    ))
    raise "append refused: #{appended.outcome}" unless appended.applied?

    @steer = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
      host: @conversation, acting_user: @human, kind: "message", role: "user",
      entries: [{ "text" => "shorter, please" }], visible_in_context: true,
      delivery_mode: "steer", context_mode: nil, context_options: nil,
      expected_context_revision: nil, expected_tail_turn_public_id: nil,
      provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
    )).value
    raise "steer not bound" unless @steer.steering_target_turn_id == @seam.turn.id
  end

  teardown do
    if @seam
      AgentRuns::Reap.destroy_aggregate(AgentRun.find(@seam.agent_run.id))
      @conversation.reload.destroy!
    end
    if @standalone
      ConversationCommandReceipt.where(host: @standalone).delete_all
      AgentRuns::Reap.destroy_aggregate(AgentRun.find(@standalone.id))
    end
  end

  def destroy_through_the_conversation_door
    Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
      host: Conversation.find(@conversation.id), acting_user: @human,
      input_public_id: @steer.public_id
    ))
  end

  def request_texts
    node = @seam.agent_run.agent_run_tasks.find_by!(node_key: "only")
    ModelInvocation.find(node.selected_model_invocation_id)
      .content_bodies.find_by!(role: "request")
      .content_body_entries.map { |e| e.content_fragment.payload.dig("parts", 0, "text") }
  end

  def finish(call)
    result = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { call.result.pop }
    raise result if result.is_a?(Exception)

    call.thread.join
    result
  end

  test "a cancel in flight lands before the peek reads: the round mints without the words" do
    held = hold_row_lock(
      ConversationInput, @steer.id,
      before_commit: ->(_locked) { assert_predicate destroy_through_the_conversation_door, :accepted? }
    )
    draining = start_database_call do
      AgentRuns::ScheduleReady.call(agent_run_id: @seam.agent_run.id)
    end
    wait_until_waiting_on_lock(draining.pid)
    release_row_lock(held)
    finish(draining)

    assert_equal ["reply"], request_texts, "the row was gone when the peek read"
    assert_not ConversationInput.exists?(@steer.id)
    assert_empty @conversation.conversation_event_items.where(item_type: "input_materialized")
  end

  test "a cancel that waits on the peek finds the row consumed, never a stale object" do
    held = hold_open_transaction do
      AgentRuns::ScheduleReady.call(agent_run_id: @seam.agent_run.id)
    end
    canceling = start_database_call { destroy_through_the_conversation_door }
    wait_until_waiting_on_lock(canceling.pid)
    release_row_lock(held)
    result = finish(canceling)

    assert_equal :not_found, result.outcome, "the words already landed; nothing to give up"
    assert_equal ["reply", "shorter, please"], request_texts
    assert_equal 1, @conversation.conversation_event_items.where(item_type: "input_materialized").count
  end

  test "a same-key race on the loop door settles the loser on the winner's receipt" do
    @standalone = seed(model("only"))
    digest = ConversationCommandReceipt.digest_for(
      operation: :input_create, envelope: { "text" => "once" }
    )
    knock = lambda do
      host = AgentRun.find(@standalone.id)
      ConversationCommandReceipt::Idempotent.call(
        account: @account, workspace: @workspace, acting_user: @human,
        operation: :input_create, idempotency_key: "same-key",
        request_digest: digest, host: host
      ) do
        result = loop_input!(host, acting_user: @human, text: "once")
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 202, body: { input: result.value.public_id }, host: host
        )
      end
    end

    held = hold_row_lock(AgentRun, @standalone.id, before_commit: ->(_locked) { @winner = knock.call })
    losing = start_database_call(&knock)
    wait_until_waiting_on_lock(losing.pid)
    release_row_lock(held)
    loser = finish(losing)

    assert_equal :executed, @winner.outcome
    assert_equal :replayed, loser.outcome, "the loser's accept rolled back with its transaction"
    assert_equal @winner.response.body.fetch(:input), loser.receipt.response_body.fetch("input")
    assert_equal 1, AgentRun.find(@standalone.id).conversation_inputs.count
    assert_equal 1, ConversationCommandReceipt.where(host: @standalone).count
  end

  test "a guarded steer waiting on the target loop refuses after its terminal transition wins" do
    held = hold_row_lock(AgentRun, @seam.agent_run.id, before_commit: ->(locked) {
      AgentRuns::Transition.agent_run(locked, status: "canceled", completed_at: Time.current)
    })
    accepting = start_database_call { guarded_steer }
    wait_until_waiting_on_lock(accepting.pid)
    release_row_lock(held)
    result = finish_database_call(accepting)

    assert_equal :steering_target_changed, result.outcome
    assert_empty ConversationInput.where.not(expected_steering_run_public_id: nil)
  ensure
    release_row_lock(held) if held&.thread&.alive?
    stop_database_call(accepting) if accepting
  end

  test "input cancellation can win while guarded target cleanup waits without a stale destroy" do
    guarded = guarded_steer.value
    body_id = guarded.content_body.id
    held = hold_open_transaction do
      result = Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: Conversation.find(@conversation.id), acting_user: @human, input_public_id: guarded.public_id
      ))
      assert_predicate result, :accepted?
    end
    stopping = start_database_call do
      agent_run = AgentRun.find(@seam.agent_run.id)
      agent_run.with_lock do
        AgentRuns::Transition.agent_run(agent_run, status: "canceled", completed_at: Time.current)
      end
    end
    wait_until_transitively_blocked_by(held.pid, stopping.pid)
    release_row_lock(held)
    finish_database_call(stopping)

    assert_equal "canceled", @seam.agent_run.reload.status
    assert_not ConversationInput.exists?(guarded.id)
    assert_not ContentBody.exists?(body_id)
    assert_equal "pending", @steer.reload.state
    assert_equal 1, @conversation.conversation_inputs.count
    assert_equal 1, @conversation.conversation_event_items.where(item_type: "input_deleted").count
  ensure
    release_row_lock(held) if held&.thread&.alive?
    stop_database_call(stopping) if stopping
  end

  test "input cancellation waits for guarded target cleanup and finds its single deletion" do
    guarded = guarded_steer.value
    body_id = guarded.content_body.id
    held = hold_open_transaction do
      agent_run = AgentRun.find(@seam.agent_run.id)
      agent_run.with_lock do
        AgentRuns::Transition.agent_run(agent_run, status: "canceled", completed_at: Time.current)
      end
    end
    canceling = start_database_call do
      Conversations::Inputs::Destroy.call(Conversations::Inputs::Destroy::Command.new(
        host: Conversation.find(@conversation.id), acting_user: @human, input_public_id: guarded.public_id
      ))
    end
    wait_until_transitively_blocked_by(held.pid, canceling.pid)
    release_row_lock(held)
    result = finish_database_call(canceling)

    assert_equal :not_found, result.outcome
    assert_not ConversationInput.exists?(guarded.id)
    assert_not ContentBody.exists?(body_id)
    assert_equal "pending", @steer.reload.state
    assert_equal 1, @conversation.conversation_inputs.count
    assert_equal 1, @conversation.conversation_event_items.where(item_type: "input_deleted").count
  ensure
    release_row_lock(held) if held&.thread&.alive?
    stop_database_call(canceling) if canceling
  end

  test "a target ending after guarded acceptance deletes the undelivered correction" do
    accepted = nil
    held = hold_open_transaction { accepted = guarded_steer }
    assert_predicate accepted, :accepted?
    stopping = start_database_call do
      agent_run = AgentRun.find(@seam.agent_run.id)
      agent_run.with_lock do
        AgentRuns::Transition.agent_run(agent_run, status: "canceled", completed_at: Time.current)
      end
    end
    wait_until_waiting_on_lock(stopping.pid)
    release_row_lock(held)
    finish_database_call(stopping)

    assert_not ConversationInput.exists?(accepted.value.id)
    assert_equal "pending", @steer.reload.state, "the ordinary steer still falls back to the queue"
    deleted = @conversation.conversation_event_items.where(item_type: "input_deleted").sole
    assert_equal accepted.value.public_id, deleted.payload.fetch("input_public_id")
    assert_equal true, deleted.payload.fetch("steer_canceled")
  ensure
    release_row_lock(held) if held&.thread&.alive?
    stop_database_call(stopping) if stopping
  end

  private

    def guarded_steer
      Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: Conversation.find(@conversation.id), acting_user: @human, kind: "message", role: "user",
        entries: [{ "text" => "this loop only" }], visible_in_context: true,
        delivery_mode: "steer", context_mode: nil, context_options: nil,
        expected_context_revision: nil, expected_tail_turn_public_id: nil,
        expected_steering_run_public_id: @seam.agent_run.public_id,
        provider_id: nil, model_ref: nil, reasoning_effort: nil, request_options: nil
      ))
    end

    # The row lock the DRAIN takes: the work runs first, inside an open
    # transaction, and its locks stay held until the test releases them.
    def hold_open_transaction
      ready = Queue.new
      release = Queue.new
      errors = Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        signaled = false
        ApplicationRecord.connection_pool.with_connection do |connection|
          ApplicationRecord.transaction do
            yield
            ready << connection.select_value("SELECT pg_backend_pid()").to_i
            signaled = true
            release.pop
          end
        end
      rescue StandardError => error
        ready << error unless signaled
        errors << error
      end

      pid = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { ready.pop }
      raise pid if pid.is_a?(Exception)

      HeldRowLock.new(thread: thread, pid: pid, release: release, errors: errors)
    end
end
