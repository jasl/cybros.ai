require "test_helper"

class Schedules::RetentionTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @owner = users(:owner)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = @account.workspaces.create!(creator: @owner, owner: @owner,
      name: "Scheduled retention", access_mode: "account_wide")
    @parent = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent, tools: [])
  end

  test "a tombstoned parent releases the undelivered original even when it has no source loop" do
    child, turn = completed_child
    assert AgentRuns::Delegations.owed_result?(turn)
    assert_predicate Conversations::Tombstone.call(conversation: @parent), :accepted?

    AgentRuns::Spawn::RelayJob.perform_now(child.id)

    assert_not_nil turn.reload.relayed_at
    assert_not AgentRuns::Delegations.owed_result?(turn)
    assert_not AgentRuns::Delegations.retained_conversation?(child.reload)
    assert_empty @parent.conversation_inputs
  end

  test "a deleted workspace can collect an undelivered child with a one-row budget before reaching its parent" do
    child, turn = completed_child
    removed = Workspaces::Delete.call(workspace: @workspace, by: @owner, lock_version: @workspace.lock_version)
    assert_equal :accepted, removed.outcome
    @workspace.with_lock { assert_equal :completed, @workspace.complete_transition }
    @workspace.update!(deleted_at: 31.days.ago)

    assert_not AgentRuns::Delegations.owed_result?(turn.reload)
    assert_not AgentRuns::Delegations.retained_conversation?(child.reload)
    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Conversation.exists?(child.id), "the newest child cannot retain the older job owner forever"
    assert Conversation.exists?(@parent.id)
    assert_equal 1, Workspaces::Collect.call(budget: 1)[:processed]
    assert_not Conversation.exists?(@parent.id)
    assert_empty Schedule.where(conversation_id: @parent.id)
  end

  test "a stopped actual source releases its report before revoked creator authority is evaluated" do
    declare_tools!(@agent)
    child, turn = completed_child
    source = turn.active_variant.agent_run
    assert_predicate AgentRuns::Stop.call(AgentRuns::Stop::Command.forced(agent_run: source, acting_user: @human)), :accepted?
    assert_equal :removed, @human.remove

    AgentRuns::Spawn::RelayJob.perform_now(child.id)

    assert_not_nil turn.reload.relayed_at
    assert_not AgentRuns::Delegations.owed_result?(turn)
    assert_empty @parent.conversation_inputs
  end

  private

    def completed_child
      at = DatabaseClock.now + 60
      result = Schedules::Create.call(conversation: @parent, creating_user: @human, attributes: {
        prompt: "Produce a report", provider_id: "dev", model_ref: "mock-text",
        rule: { "kind" => "once", "run_at" => at.iso8601(6) },
      })
      assert_predicate result, :accepted?
      job = result.value
      assert_equal :dispatched, Schedules::Dispatch.call(id: job.id, cutoff: at)
      child = job.reload.last_execution_conversation
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
      turn = child.reload.active_turn
      loop = turn.active_variant.agent_run
      if loop
        schedule_loop!(loop)
        invocation_id = loop_node(loop, "r1").selected_model_invocation_id
      else
        invocation_id = turn.active_variant.model_invocation_id
      end
      ModelInvocations::AdmitQueuedWork.call
      attempt = ModelInvocationAttempt.where(model_invocation_id: invocation_id).order(:id).last
      apply_via(attempt, sse_success("Report complete"))
      if loop
        AgentRuns::ConvergeTerminalSteps.call
        schedule_loop!(loop)
      end
      Conversations::Turns::Converge.call(conversation_id: child.id)
      assert_equal "completed", turn.reload.status
      [child, turn]
    end
end
