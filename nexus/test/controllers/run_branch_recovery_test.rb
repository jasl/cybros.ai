require "test_helper"
require_relative "../test_helpers/runs_result_delivery_test_helper"

class RunBranchRecoveryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include RunsResultDeliveryTestHelper

  setup { sign_in_as @human }

  test "a completed hosted launcher cancels its live branch while preserving the mainline and sibling" do
    _turn, run = open_turn!("Review two parts")
    call_round!(run, "r1", "delegate_task",
      { prompt: "Review the first part", wait: true }, { prompt: "Review the second part", wait: true })
    launcher = loop_node(run, "r2t0")
    branch = loop_node(run, "r2t0-model-1")
    sibling = loop_node(run, "r2t1-model-1")
    mainline = loop_node(run, "r2")
    assert_equal "completed", launcher.status
    assert_equal "running", branch.status
    @conversation.reload.update!(archived_at: Time.current)
    return_to = workspace_runs_path(@workspace, status: "running")

    get run_task_path(run, launcher.node_key), params: { return_to: return_to }
    assert_response :success
    assert_cancel_button
    assert_select "form[action=?][data-turbo-confirm]",
      run_task_cancel_path(run, launcher.node_key, return_to: return_to)
    post run_task_cancel_path(run, launcher.node_key), params: { return_to: return_to }
    assert_response :see_other
    assert_redirected_to run_task_path(run, launcher.node_key, return_to: return_to)
    assert_equal I18n.t("runs_console.branch_cancel_accepted"), flash[:notice]
    assert_equal "canceled", ModelInvocation.find(branch.selected_model_invocation_id).status
    Runs::ConvergeTerminalSteps.call
    assert_equal "canceled", branch.reload.status
    assert_equal "canceled", branch.failure_resolution
    assert_equal "task_canceled", branch.error_key
    assert_equal "completed", launcher.reload.status
    assert_equal "running", sibling.reload.status
    assert_equal "queued", mainline.reload.status
    assert_equal "running", run.reload.status
  end

  test "a standalone branch can be canceled while paused and an external return path is discarded" do
    run = standalone_branch
    paused = Runs::Pause.call(Runs::Pause::Command.graceful(run: run, acting_user: @human))
    assert_predicate paused, :accepted?

    get run_task_path(run, "background"), params: { return_to: "https://elsewhere.invalid/" }
    assert_response :success
    assert_cancel_button
    assert_select "form[action=?]", run_task_cancel_path(run, "background", return_to: run_tasks_path(run))
    post run_task_cancel_path(run, "background"), params: { return_to: "https://elsewhere.invalid/" }
    assert_response :see_other
    assert_redirected_to run_task_path(run, "background", return_to: run_tasks_path(run))
    assert_equal "canceled", loop_node(run, "background").status
    assert_equal "dispatched", loop_node(run, "mainline").status
    assert_predicate run.reload, :paused?

    post run_task_cancel_path(run, "background")
    assert_refusal :already_terminal
  end

  test "read standing hides cancellation and full standing is rechecked after the page was shown" do
    _turn, run = hosted_branch
    reader = users(:curator)
    @conversation.reload.update!(access_default: "read")
    sign_out
    sign_in_as reader

    Runs::BranchClosure.stub(:members, ->(*) { flunk "read-only detail must not expand a cancellation closure" }) do
      get run_task_path(run, "r2t0")
    end
    assert_response :success
    assert_cancel_button count: 0
    post run_task_cancel_path(run, "r2t0")
    assert_response :forbidden
    assert_equal "running", loop_node(run, "r2t0-model-1").status

    entry = @conversation.conversation_access_entries.create!(user: reader, level: "full")
    get run_task_path(run, "r2t0")
    assert_response :success
    assert_cancel_button
    entry.update!(level: "none")
    get run_task_path(run, "r2t0")
    assert_response :not_found
    post run_task_cancel_path(run, "r2t0")
    assert_response :not_found
    assert_equal "running", loop_node(run, "r2t0-model-1").status

    entry.update!(level: "full")
    post run_task_cancel_path(run, "r2t0")
    assert_response :see_other
    Runs::ConvergeTerminalSteps.call
    assert_equal "canceled", loop_node(run, "r2t0-model-1").status
  end

  test "private workspaces and tombstoned runs conceal the task and cancellation door" do
    private_run = standalone_branch(workspace: workspaces(:personal), creating_user: users(:curator))
    deleted = standalone_branch
    deleted.update!(tombstoned_at: Time.current)

    [private_run, deleted].each do |run|
      get run_task_path(run, "background")
      assert_response :not_found
      post run_task_cancel_path(run, "background")
      assert_response :not_found
      assert_equal "dispatched", loop_node(run, "background").status
    end
  end

  test "sign in resumes the task page without replaying cancellation" do
    run = standalone_branch
    task_path = run_task_path(run, "background")
    sign_out

    get task_path
    assert_redirected_to new_session_path(return_to: task_path)
    post run_task_cancel_path(run, "background"), params: { return_to: task_path }
    assert_redirected_to new_session_path(return_to: task_path)
    assert_equal "dispatched", loop_node(run, "background").status
  end

  test "cross-site cancellation is refused without changing branch work" do
    run = standalone_branch
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_changes -> { [run.reload.status, loop_node(run, "background").status, loop_node(run, "mainline").status] } do
      assert_no_enqueued_jobs do
        post run_task_cancel_path(run, "background"), headers: { "Sec-Fetch-Site" => "cross-site" }
      end
    end
    assert_response :unprocessable_entity
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "the mainline unknown tasks and terminal runs keep the existing refusal order" do
    run = standalone_branch
    get run_task_path(run, "mainline")
    assert_response :success
    assert_cancel_button count: 0
    post run_task_cancel_path(run, "mainline")
    assert_refusal :not_a_branch
    post run_task_cancel_path(run, "absent")
    assert_response :not_found
    post run_task_cancel_path(SecureRandom.uuid_v7, "background")
    assert_response :not_found
    assert_equal "dispatched", loop_node(run, "background").status

    Runs::Stop.stop_now(run)
    schedule_loop!(run)
    assert_predicate run.reload, :terminal?
    Runs::BranchClosure.stub(:members, ->(*) { flunk "terminal detail must not expand a cancellation closure" }) do
      get run_task_path(run, "background")
    end
    assert_response :success
    assert_cancel_button count: 0
    post run_task_cancel_path(run, "background")
    assert_response :conflict
    post run_task_cancel_path(run, "absent")
    assert_response :conflict
  end

  test "pruned details refuse reads and cancellation without changing retained tasks" do
    run = standalone_branch
    run.update!(details_pruned_at: Time.current)

    get run_task_path(run, "background")
    assert_response :gone
    post run_task_cancel_path(run, "background")
    assert_response :gone
    assert_equal "dispatched", loop_node(run, "background").status
  end

  test "a branch that finishes after display refuses cancellation with an actionable reason" do
    run = standalone_branch
    get run_task_path(run, "background")
    assert_response :success
    assert_cancel_button
    settled = Runs::Parks::Settle.call(node: loop_node(run, "background"), trusted: true, content: "Finished")
    assert_predicate settled, :applied?

    post run_task_cancel_path(run, "background")
    assert_refusal :already_terminal
    assert_equal "completed", loop_node(run, "background").status
    assert_equal "dispatched", loop_node(run, "mainline").status
    get run_task_path(run, "background")
    assert_response :success
    assert_cancel_button count: 0
  end

  test "an edited held run retains the cancel owner's authority over its unfinished branch" do
    turn, run = hosted_branch(wait: false)
    apply_via(attempt_for(run, "r2"), json_response(400, { "error" => "held" }))
    Runs::ConvergeTerminalSteps.call
    schedule_loop!(run)
    converge!
    assert_equal "needs_attention", run.reload.status
    assert_equal "failed", turn.reload.status
    edited = Conversations::Turns::Edit.call(Conversations::Turns::Edit::Command.new(
      conversation: @conversation, turn_public_id: turn.public_id, acting_user: @human,
      entries: [{ "text" => "A replacement answer" }]
    ))
    assert_predicate edited, :accepted?
    assert_predicate run.reload, :overridden?
    assert_equal "running", loop_node(run, "r2t0-model-1").status

    get run_task_path(run, "r2t0")
    assert_response :success
    assert_cancel_button
    post run_task_cancel_path(run, "r2t0")
    assert_response :see_other
    Runs::ConvergeTerminalSteps.call
    assert_equal "canceled", loop_node(run, "r2t0-model-1").status
    assert_equal edited.value, turn.reload.active_variant
  end

  test "branch detail reads stay read only and expose their closure size cost" do
    [5, 20].each do |count|
      run = standalone_branch
      launcher = loop_node(run, "background")
      append_branch!(launcher, Array.new(count - 1) { |index| tool("child#{index}", "read_file") })
      assert_equal count, Runs::BranchClosure.members(launcher.reload).length
      get run_task_path(run, launcher.node_key)
      assert_response :success

      statements = query_statements { get run_task_path(run, launcher.node_key) }
      assert_response :success
      assert_cancel_button
      assert_empty statements.grep(/\b(?:INSERT|UPDATE|DELETE|FOR UPDATE|FOR NO KEY UPDATE|FOR SHARE|FOR KEY SHARE)\b/i)
      reads = statements.count { |sql| sql.match?(/\A\s*(?:SELECT|WITH)\b/i) }
      edge_reads = statements.count { |sql| sql.include?('FROM "run_edges"') }
      puts "Branch cancellation detail: nodes=#{count}, sql_reads=#{reads}, edge_reads=#{edge_reads}"
    end
  end

  test "task collections do not expand cancellation closures" do
    run = standalone_branch
    Runs::BranchClosure.stub(:members, ->(*) { flunk "a task collection must not expand cancellation closures" }) do
      get run_tasks_path(run)
      assert_response :success
      get attention_path
      assert_response :success
    end
  end

  private

    def assert_cancel_button(count: 1)
      assert_select "button", text: I18n.t("runs_console.cancel_branch"), count: count
    end

    def assert_refusal(reason)
      assert_response :conflict
      assert_includes response.body, I18n.t("runs_console.refusal_reasons.#{reason}")
    end

    def standalone_branch(workspace: @workspace, creating_user: @human)
      run = seed(detached(tool("background", "read_file")), ask("mainline"),
        workspace: workspace, creating_user: creating_user)
      started = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: creating_user))
      assert_predicate started, :accepted?
      schedule_loop!(run)
      assert_equal "dispatched", loop_node(run, "background").status
      assert_equal "dispatched", loop_node(run, "mainline").status
      run.reload
    end

    def hosted_branch(wait: true)
      turn, run = open_turn!("Review the draft")
      call_round!(run, "r1", "delegate_task", { prompt: "Review this part", wait: wait })
      [turn, run]
    end

    def query_statements
      ApplicationRecord.connection_pool.clear_query_cache
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        statements << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
      statements
    end
end
