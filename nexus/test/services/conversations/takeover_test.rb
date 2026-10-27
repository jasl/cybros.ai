require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

# Real spawn, Stop, provider admission and completion writers exercise the
# ownership release. Negative controls pin why result settlement alone is insufficient.
class ConversationTakeoverTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include RowLockTestHelper
  include LockOrderTestHelper

  self.use_transactional_tests = false

  setup do
    @agent = users(:agent)
    @conversations = []
    DevModelLane.ensure_enabled!(accounts(:cybros))
    declare_tools!(@agent, tools: [Nexus::Tools::SPAWN, READ_TOOL])
    @root = Conversation.create!(workspace: workspaces(:shared),
      creating_user: users(:member), answering_user: @agent)
    @conversations << @root
    _turn, @parent = materialize_loop_reply!(@root, agent: @agent)
    schedule_loop!(@parent)
    @child, @child_run = spawn_child(@parent)
  end

  teardown do
    clear_enqueued_jobs
    @conversations.reverse_each do |conversation|
      conversation.inputs.destroy_all
      ConversationLink.for_conversation(conversation).each do |link|
        link.inputs.destroy_all
        link.destroy!
      end
      ConversationCommandReceipt.where(host: conversation).delete_all
      conversation.hosted_runs.each do |run|
        UsageRecord.where(model_invocation_public_id: run.model_invocations.select(:public_id)).delete_all
        # These cases deliberately leave obligations unfinished. Remove the
        # test-owned graph in FK order, without asserting retention eligibility.
        Runs::Reap.destroy_details(run)
        run.destroy!
      end
      UsageRecord.where(model_invocation_public_id: conversation.model_invocations.select(:public_id)).delete_all
      ModelInvocations::DrainSettled.call(conversation.model_invocations)
      ModelUsageSummary.where(subject_kind: "conversation", subject_id: conversation.id).delete_all
      destroy_memory_owner!(conversation.reload)
    end
  end

  test "direct source lock excludes the real Conversation batch Stop" do
    held = hold_row_lock(Run, @parent.id)
    stopper = start_database_call { Conversations::Turns::Cancel.stop_now(@root) }
    wait_until_transitively_blocked_by(held.pid, stopper.pid)
    refute Runs::SourceWork.execution_stopped?(@child_run)
    release_row_lock(held)
    held = nil
    assert finish_database_call(stopper).accepted?
    stopper = nil
    assert ApplicationRecord.uncached { Runs::SourceWork.execution_stopped?(@child_run) }
  ensure
    release_row_lock(held) if held
    stop_database_call(stopper) if stopper
  end

  test "Stop committed first is visible after acquiring the direct source lock" do
    held = hold_row_lock(Run, @parent.id,
      before_commit: ->(run) { Runs::Stop.cancel_locked(run) })
    candidate = start_database_call do
      @child.with_lock do
        source = Run.lock.find(@parent.id)
        Runs::SourceWork.stopped?(source.public_id, source)
      end
    end
    wait_until_transitively_blocked_by(held.pid, candidate.pid)
    release_row_lock(held)
    held = nil
    assert finish_database_call(candidate), "a takeover must refuse this committed Stop"
    candidate = nil
  ensure
    release_row_lock(held) if held
    stop_database_call(candidate) if candidate
  end

  test "direct source and target locks do not prevent ancestor Stop from fencing provider start" do
    grandchild, grandchild_run = spawn_child(@child_run)
    invocation = loop_node(grandchild_run, "r1").selected_model_invocation
    attempt = prepared_attempt(grandchild_run)
    original_ids = [grandchild.public_id, grandchild_run.public_id, invocation.public_id, attempt.public_id]

    # The proposed local critical section has passed its source check but has
    # not committed a release. These are real row locks on separate connections.
    source_lock = hold_row_lock(Run, @child_run.id)
    target_lock = hold_row_lock(Run, grandchild_run.id)
    refute Runs::SourceWork.execution_stopped?(grandchild_run)

    stopper = start_database_call { Conversations::Turns::Cancel.stop_now(@root) }
    assert finish_database_call(stopper).accepted?
    stopper = nil
    assert source_lock.thread.alive?
    assert target_lock.thread.alive?

    # This production reader locks the invocation, not either Run. A local
    # takeover that now succeeds cannot undo this observable authority loss.
    admission = ModelInvocations::ProviderStart.call(attempt: attempt,
      host: "model_runner", base_url: "http://127.0.0.1:3000/mock_llm",
      profile: DevModelLane.profile_for_invocation(invocation))
    assert_equal :authority_lost, admission.outcome
    assert_nil attempt.reload.provider_started_at
    assert_equal original_ids,
      [grandchild.public_id, grandchild_run.public_id, invocation.public_id, attempt.public_id]
    assert_equal "running", grandchild_run.reload.status
  ensure
    release_row_lock(target_lock) if target_lock
    release_row_lock(source_lock) if source_lock
    stop_database_call(stopper) if stopper
  end

  test "taken over settlement wins one slot and releases the existing wait" do
    deliver_child
    held = hold_row_lock(Run, @parent.id, before_commit: ->(run) { settle_takeover(run) })
    normal = start_database_call { Runs::Delegations::Converge.call(child: @child) }
    wait_until_transitively_blocked_by(held.pid, normal.pid)
    release_row_lock(held)
    held = nil
    refute finish_database_call(normal)
    normal = nil
    assert_taken_over
    assert_equal "completed", spawn_call.spawn_await.reload.status
    refute @child_run.reload.stopped?
    schedule_loop!(@parent)
    assert_equal "running", loop_node(@parent, "r2").status
  ensure
    release_row_lock(held) if held
    stop_database_call(normal) if normal
  end

  test "a sorted ancestor owner set fences the same Stop while the original provider can start" do
    grandchild, grandchild_run = spawn_child(@child_run)
    invocation = loop_node(grandchild_run, "r1").selected_model_invocation
    attempt = prepared_attempt(grandchild_run)
    acquired = Queue.new
    release = Queue.new
    # Experimental alternative only: a production ancestor lock cohort needs
    # an explicit change to the repository's no-ancestor-lock contract.
    candidate = start_database_call do
      grandchild.with_lock do
        Run.where(id: [@parent.id, @child_run.id, grandchild_run.id]).order(:id).lock.load
        acquired << true
        release.pop
      end
    end
    Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { acquired.pop }
    stopper = start_database_call { Conversations::Turns::Cancel.stop_now(@root) }
    wait_until_transitively_blocked_by(candidate.pid, stopper.pid)
    admission = ModelInvocations::ProviderStart.call(attempt: attempt,
      host: "model_runner", base_url: "http://127.0.0.1:3000/mock_llm",
      profile: DevModelLane.profile_for_invocation(invocation))
    assert admission.started?, admission.outcome.inspect
    assert_equal attempt.public_id, admission.attempt.public_id
    release << true
    finish_database_call(candidate)
    candidate = nil
    assert finish_database_call(stopper).accepted?
    stopper = nil
  ensure
    release << true if release
    stop_database_call(candidate) if candidate
    stop_database_call(stopper) if stopper
  end

  test "normal settlement wins and the later takeover result cannot overwrite it" do
    deliver_child
    held = hold_row_lock(Run, @parent.id)
    normal = start_database_call { Runs::Delegations::Converge.call(child: @child) }
    wait_until_transitively_blocked_by(held.pid, normal.pid)
    # Normal convergence already holds the destination Conversation, so this
    # candidate waits outside it and will observe the committed completion.
    candidate = start_database_call do
      @child.with_lock do
        Run.find(@parent.id).with_lock { settle_takeover(Run.find(@parent.id)) }
      end
    end
    wait_until_transitively_blocked_by(normal.pid, candidate.pid)
    release_row_lock(held)
    held = nil
    assert finish_database_call(normal)
    normal = nil
    refute finish_database_call(candidate)
    candidate = nil
    completion = spawn_call.spawn_delegation.reload
    assert_equal "completed", completion.status
    assert_includes completion.output_body.effective_text, "original child answer"
    refute_includes completion.output_body.effective_text, "User took over"
    assert_equal 1, completion.content_bodies.where(role: "output").count
  ensure
    release_row_lock(held) if held
    stop_database_call(normal) if normal
    stop_database_call(candidate) if candidate
  end

  test "completion alone does not release execution from stale source cleanup" do
    assert_ladder_order("experimental takeover completion") do
      @parent.with_lock { assert settle_takeover(@parent) }
    end
    assert_taken_over
    Runs::Stop.stop_now(@parent)
    Runs::Delegations::Converge.call(child: @child)
    assert @child_run.reload.stopped?, "current cleanup still owns the child despite completed settlement"
    assert_taken_over
  end

  test "released original execution survives parent Stop and stale cleanup" do
    identity = [@child.public_id, @child_run.public_id, @child_run.variant.public_id]
    assert_ladder_order("Human takeover") do
      result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
    end
    assert @child.reload.taken_over_at
    refute @child.subagent?
    assert @child_run.turn.reload.source_released_at
    assert_equal "completed", spawn_call.spawn_delegation.reload.status
    assert_equal "completed", spawn_call.spawn_await.reload.status
    Runs::Stop.stop_now(@parent)
    Runs::Delegations::Converge.call(child: @child)
    Runs::SourceWork::Recovery.call(source_run_public_id: @parent.public_id)
    refute @child_run.reload.stopped?
    refute Runs::SourceWork.execution_stopped?(@child_run)
    deliver_child
    assert_equal identity, [@child.public_id, @child_run.public_id, @child_run.variant.public_id]
  end

  test "descendant takeover rechecks its root after an ancestor takeover commits" do
    grandchild, grandchild_run = spawn_child(@child_run)
    held = hold_row_lock(Conversation, @root.id, before_commit: ->(_root) {
      result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
    })
    descendant = start_database_call do
      Conversations::Takeover.call(conversation: grandchild, acting_user: users(:member))
    end
    wait_until_transitively_blocked_by(held.pid, descendant.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(descendant)
    descendant = nil
    assert result.accepted?, result.outcome.inspect
    assert_equal @child.id, Conversations::SubagentTree.root(@child.reload).id
    assert_equal grandchild.id, Conversations::SubagentTree.root(grandchild.reload).id
    refute_includes Conversations::SubagentTree.member_ids(@root), @child.id
    refute_includes Conversations::SubagentTree.member_ids(@child), grandchild.id
    Runs::Stop.stop_now(@parent)
    Runs::Stop.stop_now(@child_run)
    refute Runs::SourceWork.execution_stopped?(grandchild_run)
  ensure
    release_row_lock(held) if held
    stop_database_call(descendant) if descendant
  end

  test "ancestor takeover excludes a descendant that became independent first" do
    grandchild, grandchild_run = spawn_child(@child_run)
    held = hold_row_lock(Conversation, @root.id, before_commit: ->(_root) {
      result = Conversations::Takeover.call(conversation: grandchild, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
    })
    ancestor = start_database_call do
      Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    end
    wait_until_transitively_blocked_by(held.pid, ancestor.pid)
    release_row_lock(held)
    held = nil
    result = finish_database_call(ancestor)
    ancestor = nil
    assert result.accepted?, result.outcome.inspect
    assert_equal @child.id, Conversations::SubagentTree.root(@child.reload).id
    assert_equal grandchild.id, Conversations::SubagentTree.root(grandchild.reload).id
    assert_equal @child.public_id, grandchild.parent_conversation_public_id
    Runs::Stop.stop_now(@parent)
    Runs::Stop.stop_now(@child_run)
    refute Runs::SourceWork.execution_stopped?(grandchild_run)
  ensure
    release_row_lock(held) if held
    stop_database_call(ancestor) if ancestor
  end

  test "source lock contention changes nothing and a rolled back Stop permits retry" do
    held = hold_row_lock(Run, @parent.id, before_commit: ->(run) {
      Runs::Stop.cancel_locked(run)
      raise ActiveRecord::Rollback
    })
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert_equal :conversation_busy, result.outcome
    assert_nil @child.reload.taken_over_at
    assert_nil @child_run.turn.reload.source_released_at
    assert_equal "running", spawn_call.spawn_delegation.reload.status
    release_row_lock(held)
    held = nil
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    refute @parent.reload.stopped?
  ensure
    release_row_lock(held) if held
  end

  test "queued request keeps its release when materialized after ancestor Stop" do
    queued, = spawn_child(@child_run, materialize: false)
    input = queued.inputs.sole
    original_input_id = input.public_id
    result = Conversations::Takeover.call(conversation: queued, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    assert input.reload.source_released_at
    Runs::Stop.stop_now(@parent)
    Runs::Stop.stop_now(@child_run)
    Runs::SourceWork::Recovery.call(source_run_public_id: @child_run.public_id)
    result = Conversations::Inputs::ApplyNext.call(conversation_id: queued.id)
    assert result.accepted?, result.outcome.inspect
    turn = result.value
    assert_equal original_input_id, turn.input_public_id
    assert turn.source_released_at
    assert_equal @child_run.public_id, turn.sender_run_public_id
    refute Runs::SourceWork.execution_stopped?(turn.active_variant.run)
  end

  test "ordinary result remains immutable when the actual takeover command follows it" do
    deliver_child
    assert Runs::Delegations::Converge.call(child: @child)
    completion = spawn_call.spawn_delegation.reload
    original_body = completion.output_body.id
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    assert_equal original_body, completion.reload.output_body.id
    assert_includes completion.output_body.effective_text, "original child answer"
    assert @child.reload.taken_over_at
  end

  test "a direct provider fallback keeps its original identity after ancestor Stop" do
    declare_tools!(@agent, tools: [], fallback_models: ["dev/mock-unmetered"])
    child, = spawn_child(@child_run, materialize: false)
    turn = Conversations::Inputs::ApplyNext.call(conversation_id: child.id).value
    invocation = turn.active_variant.model_invocation
    ModelInvocations::AdmitQueuedWork.call
    apply_via(invocation.attempts.order(:id).last, sse_refused("Cannot answer."))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    fallback = turn.reload.variants.find_by!(source: "fallback")
    original = fallback.model_invocation.public_id
    assert_equal "queued", fallback.model_invocation.status
    result = Conversations::Takeover.call(conversation: child, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    Runs::Stop.stop_now(@parent)
    Runs::Stop.stop_now(@child_run)
    Runs::SourceWork::Recovery.call(source_run_public_id: @child_run.public_id)
    refute Runs::SourceWork.stopped_variant_source?(fallback.reload)
    ModelInvocations::AdmitQueuedWork.call
    apply_via(fallback.model_invocation.attempts.order(:id).last, sse_success("Original fallback completed"))
    Conversations::Turns::Converge.call(conversation_id: child.id)
    assert_equal original, fallback.reload.model_invocation.public_id
    assert_equal "completed", fallback.model_invocation.status
    assert_equal "completed", turn.reload.status
  end

  test "an expired await retains its timeout while takeover releases the completion" do
    wait = spawn_call.spawn_await
    Task.where(id: wait.id).update_all(await_started_at: 2.hours.ago, await_timeout_ms: 1_000)
    wait.reload
    assert Runs::Parks::Settle.call(node: wait, timeout: true).moved?
    original = wait.reload.attributes.slice("status", "error_key", "completed_at")
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    assert_equal "timed_out", wait.reload.status
    assert_equal original, wait.attributes.slice("status", "error_key", "completed_at")
    assert_equal "completed", spawn_call.spawn_delegation.reload.status
    assert_equal "taken_over", Runs::TaskResultProjection.call(spawn_call.spawn_delegation).dig("structured_content", "outcome")
  end

  test "reaping the former source preserves the original independent execution and provenance" do
    source_public_id = @root.public_id
    assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
    Runs::Stop.stop_now(@parent)
    schedule_loop!(@parent)
    Conversations::Turns::Converge.call(conversation_id: @root.id, run_id: @parent.id)
    assert Conversations::Tombstone.call(conversation: @root).accepted?
    refute @child.reload.tombstoned?
    assert @parent.with_lock { Runs::Reap.destroy_aggregate(@parent) }
    assert @root.with_lock {
      MemoryCollections::Drain.call(owner: @root, budget: 20)
      Conversations::Reap.destroy_aggregate(@root)
    }
    @conversations.delete(@root)
    assert_nil @child.reload.parent_conversation_id
    assert_nil @child.spawn_node_id
    assert_equal source_public_id, @child.parent_conversation_public_id
    assert @child.taken_over_at
    refute @child.subagent?
    refute Runs::SourceWork.execution_stopped?(@child_run.reload)
    deliver_child
    assert @child_run.reload.delivered?
  end

  test "direct child Stop retains its ordinary authority after takeover" do
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert result.accepted?, result.outcome.inspect
    assert Conversations::Turns::Cancel.stop_now(@child).accepted?
    assert @child_run.reload.stopped?
    assert Runs::SourceWork.execution_stopped?(@child_run)
  end

  test "a claimed tool commits once to its original task after takeover and old cleanup" do
    run_loop_round!(@child_run, sse_success("reading", tool_calls: [
      { id: "original_read", name: "read_file", arguments: "{}" },
    ]))
    task = @child_run.tasks.find_by!(tool_call_id: "original_read")
    executor = Executor.address_for(@agent)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      run: @child_run, task_key: task.node_key, executor: executor))
    assert claimed.accepted?, claimed.outcome.inspect
    identity = [@child_run.turn.public_id, @child_run.variant.public_id, @child_run.public_id, task.id, task.node_key]
    assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
    Runs::Stop.stop_now(@parent)
    Runs::Delegations::Converge.call(child: @child)
    Runs::SourceWork::Recovery.call(source_run_public_id: @parent.public_id)
    command = Executors::Commit::Command.new(run: @child_run, task_key: task.node_key, executor: executor,
      claim_token: claimed.value.claim_token, content: [{ "type" => "text", "text" => "original tool result" }],
      structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil)
    assert Executors::Commit.call(command).applied?
    assert_equal 1, task.reload.content_bodies.where(role: "output").count
    Executors::Commit.call(command)
    assert_equal 1, task.reload.content_bodies.where(role: "output").count
    assert_equal identity, [@child_run.turn.public_id, @child_run.variant.public_id, @child_run.public_id, task.id, task.node_key]
    schedule_loop!(@child_run)
    run_loop_round!(@child_run, sse_success("original execution finished"))
    assert @child_run.reload.delivered?
  end

  %i[forced graceful replacement branch].each do |cut|
    test "#{cut} source cut committed first refuses takeover without release" do
      if cut == :branch
        @parent.with_lock { Runs::Delegations.cancel(node: spawn_call.spawn_delegation) }
      elsif cut == :replacement
        Runs::Stop.mark_now(@parent)
      else
        @parent.with_lock { Runs::Stop.cancel_locked(@parent, force: cut == :forced) }
      end
      result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      assert_equal :source_stopped, result.outcome
      assert_nil @child.reload.taken_over_at
      assert_nil @child_run.turn.reload.source_released_at
    end
  end

  test "takeover drops pending crossing messages and preserves internal links and requests" do
    grandchild, grandchild_run = spawn_child(@child_run)
    crossing = link_between(@root, @child)
    internal = link_between(@child, grandchild)
    message = linked_message(@root, @parent, @child, crossing)
    direct = linked_message(@root, @parent, @child, nil)
    retained = linked_message(@child, @child_run, grandchild, internal)
    assert_ladder_order("takeover crossing messages") do
      result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
    end
    assert_equal "taken_over", crossing.reload.close_reason
    refute Input.exists?(id: message.id)
    refute Input.exists?(id: direct.id)
    assert Input.exists?(id: retained.id)
    refute internal.reload.closed?
    assert_nil grandchild_run.turn.reload.source_released_at
    Runs::Stop.stop_now(@parent)
    refute Runs::SourceWork.execution_stopped?(grandchild_run)
    Runs::Stop.stop_now(@child_run)
    assert Runs::SourceWork.execution_stopped?(grandchild_run)
  end

  test "crossing link narration completes while a non-root ancestor Stop waits on its Run" do
    grandchild, grandchild_run = spawn_child(@child_run)
    crossing = link_between(@child, grandchild)
    message = linked_message(grandchild, grandchild_run, @child, crossing)
    acquired, proceed = Queue.new, Queue.new
    command = Conversations::Takeover.new(conversation: grandchild, acting_user: users(:member))
    command.define_singleton_method(:acquire_owners) do
      super()
      acquired << true
      proceed.pop
    end
    takeover = start_database_call { command.call }
    Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { acquired.pop }
    stopper = start_database_call { Conversations::Turns::Cancel.stop_now(@child) }
    wait_until_transitively_blocked_by(takeover.pid, stopper.pid)
    proceed << true
    result = finish_database_call(takeover)
    takeover = nil
    assert result.accepted?, result.outcome.inspect
    assert finish_database_call(stopper).accepted?
    stopper = nil
    assert_equal "taken_over", crossing.reload.close_reason
    refute Input.exists?(id: message.id)
    refute Runs::SourceWork.execution_stopped?(grandchild_run)
  ensure
    proceed << true if proceed
    stop_database_call(takeover) if takeover
    stop_database_call(stopper) if stopper
  end

  test "a settlement failure rolls back the entire takeover" do
    Runs::Delegations::Settlement.stub(:call_locked, ->(**) { raise "injected settlement failure" }) do
      error = assert_raises(RuntimeError) do
        Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      end
      assert_equal "injected settlement failure", error.message
    end
    assert_nil @child.reload.taken_over_at
    assert_nil @child_run.turn.reload.source_released_at
    assert_equal "running", spawn_call.spawn_delegation.reload.status
    assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
  end

  test "multiple incoming requests settle together under the real lock ladder" do
    grandchild, = spawn_child(@child_run)
    extra = request_from(@parent, grandchild, key: "followup")
    schedule_loop!(@parent)
    assert_equal "running", extra.spawn_delegation.reload.status
    assert_ladder_order("multiple takeover completions") do
      result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
    end
    [spawn_call, extra].each do |call|
      node = call.spawn_delegation.reload
      assert_equal "completed", node.status
      assert_equal "taken_over", Runs::TaskResultProjection.call(node).dig("structured_content", "outcome")
    end
    assert grandchild.inputs.find_by!(public_id: extra.spawn_delegation.delegated_input_public_id).source_released_at
  end

  test "publication before observer dispatch refuses atomically and succeeds after scheduling" do
    extra = request_from(@parent, @child, key: "followup")
    assert_equal "queued", extra.spawn_delegation.reload.status
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert_equal :conversation_busy, result.outcome
    assert_nil @child.reload.taken_over_at
    assert_nil @child_run.turn.reload.source_released_at
    schedule_loop!(@parent)
    assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
  end

  test "an unrelated active request refuses takeover without stealing its obligation" do
    other = Conversation.create!(workspace: workspaces(:shared), creating_user: users(:member), answering_user: @agent)
    @conversations << other
    _turn, other_run = materialize_loop_reply!(other, agent: @agent)
    schedule_loop!(other_run)
    extra = request_from(other_run, @child, key: "external")
    schedule_loop!(other_run)
    result = Conversations::Takeover.call(conversation: @child, acting_user: users(:member))
    assert_equal :conflicting_request_owner, result.outcome
    assert_nil @child.reload.taken_over_at
    assert_nil @child_run.turn.reload.source_released_at
    assert_equal "running", extra.spawn_delegation.reload.status
  end

  test "spawn waiting on the former root joins the newly independent lifecycle tree" do
    held = hold_row_lock(Conversation, @root.id, before_commit: ->(_root) {
      assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
    })
    spawner = start_database_call { spawn_child(@child_run) }
    wait_until_transitively_blocked_by(held.pid, spawner.pid)
    release_row_lock(held)
    held = nil
    grandchild, run = finish_database_call(spawner)
    spawner = nil
    assert_equal @child.id, Conversations::SubagentTree.root(grandchild).id
    refute_includes Conversations::SubagentTree.member_ids(@root), grandchild.id
    assert Conversations::Archive.call(conversation: @root).accepted?
    refute grandchild.reload.archived?
    Runs::Stop.stop_now(@parent)
    refute Runs::SourceWork.execution_stopped?(run)
  ensure
    release_row_lock(held) if held
    stop_database_call(spawner) if spawner
  end

  test "an admitted provider attempt completes without a second start after takeover" do
    invocation = loop_node(@child_run, "r1").selected_model_invocation
    attempt = prepared_attempt(@child_run)
    built = build(attempt)
    assert built.built?
    admission = ModelInvocations::ProviderStart.call(attempt: attempt,
      host: "model_runner", base_url: "http://127.0.0.1:3000/mock_llm",
      profile: DevModelLane.profile_for_invocation(invocation))
    assert admission.started?, admission.outcome.inspect
    start = attempt.reload.provider_started_at
    assert Conversations::Takeover.call(conversation: @child, acting_user: users(:member)).accepted?
    Runs::Stop.stop_now(@parent)
    fake_dispatch(sse_success("same admitted request finished")) do
      outcome = ModelInvocations::Dispatch.call(attempt: admission.attempt, context: admission.context, request: built.request)
      ModelInvocations::ApplyResult.call(attempt: admission.attempt, outcome: outcome)
    end
    Runs::ConvergeTerminalSteps.call
    Runs::ScheduleReady.call(run_id: @child_run.id)
    assert @child_run.reload.delivered?
    assert_equal start, attempt.reload.provider_started_at
    assert_equal [attempt.id], invocation.attempts.pluck(:id)
  end

  private

    def request_from(source, target, key:)
      call = source.tasks.create!(type: Tasks::ToolTask.sti_name, node_key: key, authored_by: "author",
        tool_name: "request", tool_input: { "to" => target.public_id, "prompt" => "Follow up", "lifetime" => "conversation" })
      call.update_columns(status: "running", started_at: Time.current)
      assert_equal :applied, Runs::ConversationRequest::Run.call(node: call)
      refute call.reload.output_summary["is_error"], call.output_body&.effective_text
      call
    end

    def link_between(first, second)
      result = Conversations::Links::Create.call(conversation: first, agent: @agent,
        peer_conversation: second, peer_agent: @agent, acting_user: users(:member))
      assert result.accepted?, result.outcome.inspect
      result.value
    end

    def linked_message(source, run, target, link)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.sent(
        host: target, acting_user: @agent, entries: [{ "text" => "queued link message" }],
        sender_conversation_public_id: source.public_id, run_public_id: run.public_id,
        task_key: "message", kind: "direct_reply", delivery_mode: "queue", communication_kind: "message",
        conversation_link: link, answering_user_public_id: @agent.public_id))
      assert result.accepted?, result.outcome.inspect
      result.value
    end

    def second_root_run
      deliver_child
      Runs::Delegations::Converge.call(child: @child)
      schedule_loop!(@parent)
      run_loop_round!(@parent, sse_success("parent finished"))
      Conversations::Turns::Converge.call(conversation_id: @root.id, run_id: @parent.id)
      _turn, run = materialize_loop_reply!(@root.reload, agent: @agent)
      assert_operator run.id, :>, @parent.id
      run
    end

    def prepared_attempt(run)
      ModelInvocations::AdmitQueuedWork.call
      clear_enqueued_jobs
      loop_node(run, "r1").selected_model_invocation.attempts.order(:id).last
    end

    def spawn_child(parent, materialize: true)
      apply_via(prepared_attempt(parent), sse_success("delegating", tool_calls: [
        { id: "spawn_child", name: "spawn", arguments: { prompt: "Work on the original execution", lifetime: "turn", wait: true }.to_json },
      ]))
      Runs::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: parent.id)
      end
      child = Conversation.find_by!(spawn_node_id: loop_node(parent, "r2t0").id)
      @conversations << child
      return [child, nil] unless materialize

      result = Conversations::Inputs::ApplyNext.call(conversation_id: child.id)
      assert result.accepted?, result.outcome.inspect
      run = result.value.active_variant.run
      schedule_loop!(run)
      assert_equal @agent.id, child.answering_user_id
      [child, run]
    end

    def spawn_call = loop_node(@parent, "r2t0")

    def deliver_child
      apply_via(prepared_attempt(@child_run), sse_success("original child answer"))
      Runs::ConvergeTerminalSteps.call
      Runs::ScheduleReady.call(run_id: @child_run.id)
      assert @child_run.reload.delivered?
      clear_enqueued_jobs
    end

    # Only the result-slot candidate: deliberately does not pretend that
    # settling this task implements lifecycle or request-ownership release.
    def settle_takeover(source)
      call = source.tasks.find_by!(node_key: "r2t0")
      Runs::Delegations::Settlement.call(node: call.spawn_delegation, call: call,
        child: @child, text: "User took over; work continues independently.", status: "completed",
        execution_identity: { "outcome" => "taken_over", "run_public_id" => @child_run.public_id })
    end

    def assert_taken_over
      completion = spawn_call.spawn_delegation.reload
      assert_equal "completed", completion.status
      assert_equal "User took over; work continues independently.", completion.output_body.effective_text
      assert_equal 1, completion.content_bodies.where(role: "output").count
    end
end
