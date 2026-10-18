require "test_helper"
require_relative "../test_helpers/conversation_recovery_test_helper"

class ConversationRecoveryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ConversationRecoveryTestHelper

  setup do
    prepare_recovery_conversation
    sign_in_as @human
  end

  test "a cost edit preserves exact decimals, clears explicitly, and never creates work" do
    get edit_conversation_cost_limit_path(@conversation)
    assert_response :success
    version = @conversation.lock_version
    assert_select "input[name='cost_limit[lock_version]'][value=?]", version.to_s
    amount = "12.123456789012345678"
    assert_no_difference ["Turn.count", "Variant.count", "Task.count", "ModelInvocation.count"] do
      patch_limit(amount, version: version, return_to: "/conversations?archived=include")
    end
    assert_redirected_to "/conversations?archived=include"
    assert_equal amount, @conversation.reload.cost_limit.to_s("F")
    patch_limit("")
    assert_response :see_other
    assert_nil @conversation.reload.cost_limit
    patch_limit("0")
    assert_equal 0.to_d, @conversation.reload.cost_limit
  end

  test "invalid amounts preserve the typed draft and original version without changing the limit" do
    ["NaN", "Infinity", "-1", "1e20", "1e-19", "mistyped"].each do |amount|
      version = @conversation.reload.lock_version
      patch_limit(amount, version: version)
      assert_response :unprocessable_entity
      assert_select "input[name='cost_limit[amount]'][value=?]", amount
      assert_select "input[name='cost_limit[lock_version]'][value=?]", version.to_s
      assert_equal 0.to_d, @conversation.reload.cost_limit
    end
    @conversation.update!(cost_limit: nil)
    @account.update!(cost_unit: nil)
    patch_limit("1")
    assert_response :unprocessable_entity
    assert_nil @conversation.reload.cost_limit
  end

  test "stale drafts keep the submitted version until an explicit current-version save" do
    old_version = @conversation.lock_version
    @conversation.update!(cost_limit: "8")
    patch_limit("12.2500", version: old_version)
    assert_response :conflict
    assert_select "input[name='cost_limit[amount]'][value='12.2500']"
    assert_select "input[name='cost_limit[lock_version]'][value=?]", old_version.to_s
    assert_select "button[name='cost_limit[lock_version]'][value=?]", @conversation.lock_version.to_s
    assert_includes response.body, "Current limit: 8.0 USD"
    assert_equal 8.to_d, @conversation.reload.cost_limit
    patch_limit("12.2500", version: @conversation.lock_version)
    assert_response :see_other
    assert_equal "12.25", @conversation.reload.cost_limit.to_s("F")
  end

  test "cost-only edits work after Conversation archive and remain subject to Workspace access" do
    @conversation.update!(archived_at: Time.current)
    patch_limit("3")
    assert_response :see_other
    assert @conversation.reload.archived?
    Workspaces::Archive.call(workspace: @workspace, by: @workspace.owner, lock_version: @workspace.lock_version)
    Workspaces::CompleteTransition.call(workspace: @workspace)
    assert_predicate @workspace.reload, :archived?
    patch_limit("4")
    assert_response :forbidden
    assert_equal 3.to_d, @conversation.reload.cost_limit
  end

  test "read-only and concealed members cannot change a cap or see unauthorized edit controls" do
    @conversation.update!(access_default: "read")
    get conversation_path(@conversation)
    assert_response :success
    assert_select "a[href^=?]", edit_conversation_cost_limit_path(@conversation), count: 0
    get edit_conversation_cost_limit_path(@conversation)
    assert_response :forbidden
    patch_limit("7")
    assert_response :forbidden
    @conversation.update!(access_default: "none")
    get edit_conversation_cost_limit_path(@conversation)
    assert_response :not_found
    patch_limit("7")
    assert_response :not_found
    assert_equal 0.to_d, @conversation.reload.cost_limit
  end

  test "a failed direct reply remains recoverable after the current cap is cleared" do
    cost_refused_reply
    patch_limit("")
    assert_response :see_other
    get conversation_path(@conversation)
    assert_select "[data-cost-recovery]"
    assert_includes response.body, I18n.t("management_console.continue_in_app")
    assert_nil @conversation.reload.active_turn_id
    get conversation_turn_variant_path(@conversation, @turn.public_id, @original.public_id)
    assert_select "[data-cost-recovery]"
    assert_equal "failed", @original.reload.status
  end

  test "a held Run keeps completed tools and uses its original Task retry after raising the cap" do
    held_run_with_completed_tool
    effect = @tool.reload.attributes.slice("status", "execution_generation", "completed_at", "output_summary")
    output_id = @tool.output_body.id
    run_id = @run.id
    generation = @failed_task.execution_generation
    original_count = @run.tasks.count
    task_path = run_task_path(@run, @failed_task.node_key)
    get task_path
    assert_select "[data-cost-recovery]"
    patch_limit("2", return_to: task_path)
    assert_redirected_to task_path
    assert_equal "needs_attention", @run.reload.status
    assert_equal "failed", @failed_task.reload.status
    post run_task_retry_path(@run, @failed_task.node_key)
    assert_response :see_other
    assert_equal generation + 1, @failed_task.reload.execution_generation
    assert_equal run_id, @run.reload.id
    assert_equal original_count, @run.tasks.count
    assert_equal effect, @tool.reload.attributes.slice(*effect.keys)
    assert_equal output_id, @tool.output_body.id
    assert_equal "Already read", @tool.output_body.effective_text
    schedule_loop!(@run)
    run_loop_round!(@run, sse_success("Continued without another tool call"))
    Conversations::Turns::Converge.call
    assert_equal "completed", @run.reload.status
    assert_equal "completed", @turn.reload.status
  end

  test "source execution configuration and cost refusal do not escape through inherited content" do
    cost_refused_reply
    fork = Conversation.create!(workspace: @workspace, creating_user: @human)
    ConversationAncestry.create!(account: @account, conversation: fork,
      ancestor_conversation: @conversation, depth: 1, boundary_position: @turn.position)
    @conversation.reload.update!(access_default: "none")
    read = Conversations::Reader.new(fork, user: @human).variant(
      turn_public_id: @turn.public_id, variant_public_id: @original.public_id)
    assert_nil read.variant_record
    assert_not read.cost_refused
    assert_empty Conversations::Reader.new(fork, user: @human).page.cost_refused_variant_ids
    get conversation_turn_variant_path(fork, @turn.public_id, @original.public_id)
    assert_response :success
    assert_select "[data-cost-recovery]", count: 0
  end

  test "cost edits reject missing versions and require sign in" do
    patch conversation_cost_limit_path(@conversation), params: { cost_limit: { amount: "1" } }
    assert_response :bad_request
    cost_refused_reply
    sign_out
    get edit_conversation_cost_limit_path(@conversation)
    assert_redirected_to new_session_path(return_to: edit_conversation_cost_limit_path(@conversation))
  end

  private

    def patch_limit(amount, version: @conversation.reload.lock_version, return_to: nil)
      patch conversation_cost_limit_path(@conversation), params: {
        cost_limit: { amount: amount, lock_version: version }, return_to: return_to,
      }
    end
end
