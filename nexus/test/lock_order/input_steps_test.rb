require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class InputStepsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    declare_tools!(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "materialization accepts authored attachments before sealing the original model input" do
    upload = create_content_upload(account: @account)
    input = queued([parallel(model("review", "attachments" => [upload.public_id])), ask("hold")])
    assert_empty ContentBodyUpload.where(content_upload: upload), "steps do not bind staged uploads while queued"

    sequences = assert_ladder_order("authored input steps with attachments") do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate result, :accepted?, result.outcome.to_s
    end

    locks = sequences.flatten
    assert_operator locks.index("agent_runs"), :<, locks.index("content_uploads")
    assert_operator locks.index("content_uploads"), :<, locks.index("content_fragments")
    run = @conversation.conversation_turns.sole.active_variant.agent_run
    assert_equal [upload.id], loop_node(run, "review").input_body.content_uploads.pluck(:id)
    assert_equal @human, run.creating_user
    assert_equal input.public_id, run.agent_run_append_receipts.sole.idempotency_key
    assert_predicate loop_node(run, "r1").input_body, :sealed?
  end

  test "a capture lost while queued blocks materialization without a partial run" do
    upload = create_content_upload(account: @account)
    input = queued([parallel(model("review", "attachments" => [upload.public_id])), ask("hold")])
    upload.destroy!

    assert_no_difference ["AgentRun.count", "ConversationTurn.count", "AgentRunTask.count"] do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_equal :input_blocked, result.outcome
    end
    assert_equal "unknown_input_upload", input.reload.blocked_reason
  end

  test "the host default is resolved at materialization and later changes do not redirect accepted work" do
    first = suite_runner
    second = connect_runner(manager: users(:owner), registration_identifier: "second-input-runner",
      display_name: "Second runner", assignment_scope: :account_wide).executor_access_token.task_executor
    assert_predicate second.announce(tools: TEST_SERVED_TOOLS), :accepted?
    @agent.update!(runner_executor_public_ids: [first.public_id, second.public_id])
    @conversation.set_default_runner(first, by: @human)
    queued([tool("check", "bash", "input" => { "command" => "true" }), ask("hold")])
    @conversation.set_default_runner(second, by: @human)

    sequences = assert_ladder_order("authored input steps with current Runner") do
      result = Conversations::Inputs::ApplyNext.call(conversation_id: @conversation.id)
      assert_predicate result, :accepted?, result.outcome.to_s
    end
    assert_equal 1, sequences.flatten.count("agent_runs"), "the second append reuses the newborn Run lock"
    run = @conversation.conversation_turns.sole.active_variant.agent_run
    check = loop_node(run, "check")
    assert_equal second.public_id, check.target_executor_public_id
    @conversation.set_default_runner(first, by: @human)
    assert_equal second.public_id, check.reload.target_executor_public_id
  end

  private

    def queued(steps)
      post_input!(@conversation, acting_user: @human, kind: "direct_reply", text: "Produce a result",
        provider_id: "dev", model_ref: "mock-text", steps: steps)
    end
end
