require "test_helper"
require_relative "../test_helpers/compaction_test_helper"
require_relative "../test_helpers/rate_limit_test_helper"

class RunCompactionRecoveryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include CompactionTestHelper
  include RateLimitTestHelper

  HOOK_TOOL = "check_compaction".freeze
  SUMMARY_TOOL = "summarize_history".freeze
  DELEGATE = { "mode" => "delegate", "tool_name" => SUMMARY_TOOL }.freeze

  setup { sign_in_as @human }

  test "a queued model task offers compaction without serializing history or changing execution" do
    run = queued_run
    task = node(run, "next")
    before = [run.reload.attributes, task.attributes]

    Conversations::Compaction::Serialize.stub(:loop_entries, ->(*) { flunk "Task reads must not serialize history" }) do
      assert_no_queries_match(/FOR (?:NO KEY )?UPDATE/i) do
        assert_no_difference ["Task.count", "ModelInvocation.count"] do
          assert_no_enqueued_jobs do
            get run_task_path(run, task.node_key)
          end
        end
      end
    end

    assert_response :success
    assert_select "button", text: I18n.t("runs_console.compact"), count: 1
    assert_select "form[action^=?][method=post]", run_task_compact_path(run, task.node_key), count: 1
    assert_select "a", text: I18n.t("runs_console.compaction_step"), count: 0
    assert_equal before, [run.reload.attributes, task.reload.attributes]
  end

  test "submitting a queued task without history refuses before creating a compaction step" do
    run = queued_run

    assert_no_difference ["Task.count", "ModelInvocation.count"] do
      post run_task_compact_path(run, "next")
    end

    assert_response :conflict
    assert_includes response.body, I18n.t("runs_console.refusal_reasons.nothing_to_compact")
    assert_equal "queued", node(run, "next").status
    assert_nil node(run, "next").compaction
  end

  test "compaction rate limiting refuses further work before calling the domain command" do
    run = run_with_history
    keys = capture_rate_limit_keys do
      post run_task_compact_path(run, "next")
      assert_response :see_other
    end
    key = keys.uniq.sole
    Rails.cache.write(key, 60, expires_in: 1.minute)

    Runs::Tasks::Compact.stub(:call, ->(*) { flunk "rate limited requests must not invoke compaction" }) do
      assert_no_difference ["Task.count", "ModelInvocation.count"] do
        assert_no_enqueued_jobs do
          post run_task_compact_path(run, "next")
        end
      end
    end
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_select "[role=alert]", text: /Too many requests/
  ensure
    Rails.cache.delete(key) if key
  end

  test "cross-site compaction is refused without creating summary work" do
    run = run_with_history
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference ["Task.count", "ModelInvocation.count"] do
      assert_no_enqueued_jobs do
        post run_task_compact_path(run, "next"), headers: { "Sec-Fetch-Site" => "cross-site" }
      end
    end
    assert_response :unprocessable_entity
    assert_nil node(run, "next").compaction
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "a paused run accepts compaction and executes its summary only after explicit resume" do
    run = run_with_history
    target = node(run, "next")
    return_to = workspace_runs_path(@workspace, status: "paused")
    original_path = run_task_path(run, target.node_key, return_to: return_to)
    post run_pause_path(run)
    assert_response :see_other
    assert_predicate run.reload, :paused?

    get original_path
    assert_select "button", text: I18n.t("runs_console.compact"), count: 1
    assert_difference -> { run.tasks.count }, 1 do
      post run_task_compact_path(run, target.node_key), params: { return_to: return_to }
    end
    assert_redirected_to original_path
    assert_equal I18n.t("runs_console.compaction_accepted"), flash[:notice]
    assert_predicate run.reload, :paused?
    summary = current_summary(run, target)

    assert_no_difference "ModelInvocation.count" do
      schedule_loop!(run)
    end
    assert_equal "queued", summary.reload.status
    assert_equal "queued", target.reload.status
    assert_compaction_step(run, target, summary, state: :waiting, return_to: return_to)
    assert_includes response.body, I18n.t("runs_console.compaction_paused")

    post run_resume_path(run)
    assert_response :see_other
    schedule_loop!(run)
    assert_equal "running", summary.reload.status
    run_loop_round!(run, sse_success("Read the original ledger for the retained details."))
    assert_predicate summary.reload, :usable_summary?
    assert_compaction_step(run, target, summary, state: :ready, return_to: return_to)

    get run_task_path(run, summary.node_key, return_to: original_path)
    assert_response :success
    assert_select "a[href=?]", original_path, text: I18n.t("runs_console.back"), count: 1
    assert_includes response.body, "Read the original ledger for the retained details."
    assert_no_difference "Task.count" do
      post run_task_compact_path(run, target.node_key)
    end
    assert_response :conflict
  end

  test "the original task follows its pre hook then delegate and kernel fallback through persisted links" do
    announce_tools!(@agent, [HOOK_TOOL, SUMMARY_TOOL])
    @agent.update!(approval_mode: "bypass",
      lifecycle_hooks: { "pre_compact" => { "tool" => HOOK_TOOL, "timeout_ms" => 30_000 } })
    run = run_with_history(compaction: DELEGATE, creating_user: @agent)
    target = node(run, "next")

    post run_task_compact_path(run, target.node_key)
    assert_response :see_other
    hook = Runs::LifecycleHooks.find(run, "pre_compact", target)
    assert hook
    assert_nil target.reload.compaction[Tasks::ModelTask::SUMMARY_SOURCE]
    assert_compaction_step(run, target, hook, state: :hook)

    schedule_loop!(run)
    commit_tool(hook, content: "Ready to summarize.", structured_content: { "continue" => false })
    assert_compaction_step(run, target, hook, state: :hook_finished)
    2.times { schedule_loop!(run) }
    delegate = current_summary(run, target)
    assert_equal SUMMARY_TOOL, delegate.tool_name
    assert_not_equal hook.id, delegate.id
    assert_compaction_step(run, target, delegate, state: :waiting)
    assert_select "a[href^=?]", run_task_path(run, hook.node_key), count: 0

    claim_tool(delegate)
    Task.where(id: delegate.id).update_all(await_started_at: 2.hours.ago)
    Runs::Parks::TimeoutSweep.call
    assert_equal "timed_out", delegate.reload.status
    fallback = current_summary(run, target)
    assert_not_equal delegate.id, fallback.id
    assert_predicate fallback, :model_task?
    assert_equal fallback.node_key, delegate.compaction.fetch(Conversations::Compaction::Fallback::DELEGATE_FALLBACK)
    assert_compaction_step(run, target, fallback, state: :waiting)
    assert_select "a[href^=?]", run_task_path(run, delegate.node_key), count: 0
  end

  test "a completed prune no longer presents its pre hook as a pending summary step" do
    declare_tools!(@agent)
    @agent.update!(approval_mode: "bypass", lifecycle_hooks: {
      "pre_compact" => { "tool" => HOOK_TOOL, "timeout_ms" => 30_000 },
      "post_compact" => { "tool" => HOOK_TOOL, "timeout_ms" => 30_000 },
    })
    announce_tools!(@agent, [HOOK_TOOL, "read_file"])
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    _turn, run = materialize_loop_reply!(conversation, agent: @agent)
    schedule_loop!(run)
    2.times do |index|
      words = index.zero? ? "earlier answer. " * 1_500 : "noted"
      run_loop_round!(run, sse_success(words, tool_calls: [
        { id: "read#{index}", name: "read_file", arguments: '{"path":"notes.txt"}' },
      ]))
      commit_tool(run.tasks.find_by!(tool_call_id: "read#{index}"), content: "result. " * 1_000)
      schedule_loop!(run) if index.zero?
    end
    target = run.reload.deliverable_node
    assert_equal "queued", target.status
    trigger = Conversations::Compaction::Trigger.wall(target,
      overshoot: Conversations::Compaction::Overshoot.bytes(100))
    repair = run.with_lock { Conversations::Compaction::Arm.call(run: run, node: target, trigger: trigger) }
    assert_equal "hook", repair.mode
    schedule_loop!(run)
    hook = Runs::LifecycleHooks.find(run, "pre_compact", target)
    assert_compaction_step(run, target, hook, state: :hook)
    commit_tool(hook, content: "Ready to compact.", structured_content: { "continue" => false })
    2.times { schedule_loop!(run) }

    assert target.reload.pruned_before
    assert_nil target.compaction[Tasks::ModelTask::SUMMARY_SOURCE]
    assert_equal "queued", target.status
    get run_task_path(run, target.node_key)
    assert_response :success
    assert_select "a", text: I18n.t("runs_console.compaction_step"), count: 0
    assert_select "p[role=status]", text: I18n.t("runs_console.compaction_states.hook"), count: 0
    assert_select "button", text: I18n.t("runs_console.compact"), count: 0

    after = Runs::LifecycleHooks.find(run, "post_compact", target)
    commit_tool(after, content: "Compaction acknowledged.", structured_content: { "continue" => false })
    schedule_loop!(run)
    assert_equal "running", target.reload.status
    get run_task_path(run, target.node_key)
    assert_response :success
    assert_select "a", text: I18n.t("runs_console.compaction_step"), count: 0
  end

  test "a between-turn summary seed never presents its own pre hook as another summary request" do
    announce_tools!(@agent, [HOOK_TOOL])
    @agent.update!(approval_mode: "bypass",
      lifecycle_hooks: { "pre_compact" => { "tool" => HOOK_TOOL, "timeout_ms" => 30_000 } })
    conversation = Conversation.create!(workspace: @workspace, creating_user: @agent)
    post_input!(conversation, acting_user: @human, text: "Keep the orchard ledger decision.")
    Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
    requested = Conversations::Compaction::Request.call(Conversations::Compaction::Request::Command.new(
      conversation: conversation, acting_user: @agent, model: "dev/mock-text"
    ))
    assert_predicate requested, :accepted?
    turn = requested.value.turn
    assert_predicate turn, :compaction_summary?
    run = turn.active_variant.run
    summary = run.deliverable_node
    2.times { schedule_loop!(run) }
    hook = Runs::LifecycleHooks.find(run, "pre_compact", summary)
    assert hook
    get run_task_path(run, summary.node_key)
    assert_response :success
    assert_select "a", text: I18n.t("runs_console.compaction_step"), count: 0

    commit_tool(hook, content: "Ready to summarize.", structured_content: { "continue" => false })
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Retain the orchard ledger decision."))
    Conversations::Turns::Converge.call(conversation_id: conversation.id, run_id: run.id)
    assert_predicate summary.reload, :usable_summary?
    assert_equal "completed", turn.reload.status
    get run_task_path(run, summary.node_key)
    assert_response :success
    assert_select "a", text: I18n.t("runs_console.compaction_step"), count: 0
    assert_select "p[role=status]", text: I18n.t("runs_console.compaction_states.hook"), count: 0
    assert_includes response.body, "Retain the orchard ledger decision."
  end

  test "failed empty and error delegate results never appear as a usable summary" do
    announce_tools!(@agent, [SUMMARY_TOOL])
    [
      { content: "No summary could be produced.", outcome: "failed" },
      { content: "" },
      { content: "The summary service reported an error.", is_error: true },
    ].each do |result|
      run = run_with_history(compaction: DELEGATE, creating_user: @agent)
      target = node(run, "next")
      post run_task_compact_path(run, target.node_key)
      assert_response :see_other
      summary = current_summary(run, target)
      schedule_loop!(run)
      commit_tool(summary, **result)

      assert_not summary.reload.usable_summary?
      assert_equal result.fetch(:outcome, "completed"), summary.status
      assert_compaction_step(run, target, summary, state: :unavailable)
      assert_not_includes response.body, I18n.t("runs_console.compaction_states.ready")
      get run_task_path(run, summary.node_key)
      assert_response :success
      assert_includes response.body, result.fetch(:content) unless result.fetch(:content).empty?
    end
  end

  test "read-only members can inspect but cannot compact and concealed conversations remain absent" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: "read")
    seam = create_run_backed_turn(conversation: conversation, acting_user: users(:owner))
    grow!(seam.run, model("next"))

    get run_task_path(seam.run, "next")
    assert_response :success
    assert_select "button", text: I18n.t("runs_console.compact"), count: 0
    assert_no_difference "Task.count" do
      post run_task_compact_path(seam.run, "next")
    end
    assert_response :forbidden
    conversation.update!(access_default: "none")
    get run_task_path(seam.run, "next")
    assert_response :not_found
    post run_task_compact_path(seam.run, "next")
    assert_response :not_found
  end

  test "unknown task keys and inaccessible or deleted runs cannot create compaction work" do
    run = queued_run
    private_run = seed(model("private"), workspace: workspaces(:personal), creating_user: users(:curator))
    [
      run_task_compact_path(run, "missing"),
      run_task_compact_path(run, "private"),
      run_task_compact_path(SecureRandom.uuid_v7, "next"),
      run_task_compact_path(private_run, "private"),
    ].each do |path|
      assert_no_difference "Task.count" do
        post path
      end
      assert_response :not_found
    end
    run.update!(tombstoned_at: Time.current)
    post run_task_compact_path(run, "next")
    assert_response :not_found
  end

  test "pruned execution details refuse both the task page and compaction command" do
    run = queued_run
    run.update!(details_pruned_at: Time.current)

    get run_task_path(run, "next")
    assert_response :gone
    ["next", "missing"].each do |key|
      assert_no_difference "Task.count" do
        post run_task_compact_path(run, key)
      end
      assert_response :gone
    end
  end

  test "a task that starts after its page was read is refused without a replacement request" do
    run = queued_run
    get run_task_path(run, "next")
    assert_response :success
    assert_select "button", text: I18n.t("runs_console.compact"), count: 1
    schedule_loop!(run)
    assert_equal "running", node(run, "next").status

    assert_no_difference ["Task.count", "ModelInvocation.count"] do
      post run_task_compact_path(run, "next")
    end

    assert_response :conflict
    assert_includes response.body, I18n.t("runs_console.refusal_reasons.task_not_queued")
    get run_task_path(run, "next")
    assert_select "button", text: I18n.t("runs_console.compact"), count: 0
  end

  test "disabled compaction and raw kernel input hide the button and retain their refusal" do
    [
      [queued_run(compaction: { "mode" => "off" }), :compaction_disabled],
      [queued_run(prompt_mechanism: "raw"), :compaction_unavailable_under_raw],
    ].each do |run, reason|
      get run_task_path(run, "next")
      assert_response :success
      assert_select "button", text: I18n.t("runs_console.compact"), count: 0
      assert_no_difference "Task.count" do
        post run_task_compact_path(run, "next")
      end
      assert_response :conflict
      assert_includes response.body, I18n.t("runs_console.refusal_reasons.#{reason}")
    end
  end

  test "an external return destination falls back to the original run task list" do
    run = run_with_history

    post run_task_compact_path(run, "next"), params: { return_to: "https://example.com/elsewhere" }

    assert_redirected_to run_task_path(run, "next", return_to: run_tasks_path(run))
  end

  private

    def queued_run(compaction: nil, **options)
      run = seed(model("next", "compaction" => compaction), **options)
      started = Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
      assert_predicate started, :accepted?
      clear_enqueued_jobs
      run
    end

    def run_with_history(compaction: nil, creating_user: @human)
      run = create_loop!(model("earlier", "prompt" => "Inspect the orchard ledger."),
        model("next", "prompt" => "Continue from the earlier findings.", "compaction" => compaction),
        creating_user: creating_user)
      settle!(run, "earlier", "The ledger is available for the next step.")
      assert_equal "queued", node(run, "next").status
      run
    end

    def current_summary(run, target)
      node(run, target.reload.compaction.fetch(Tasks::ModelTask::SUMMARY_SOURCE))
    end

    def assert_compaction_step(run, target, step, state:, return_to: nil)
      path = run_task_path(run, target.node_key, return_to: return_to)
      get path
      assert_response :success
      assert_select "a[href=?]", run_task_path(run, step.node_key, return_to: path),
        text: I18n.t("runs_console.compaction_step"), count: 1
      assert_select "p[role=status]", text: I18n.t("runs_console.compaction_states.#{state}"), count: 1
      assert_select "button", text: I18n.t("runs_console.compact"), count: 0
    end

    def claim_tool(task)
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        run: task.run, task_key: task.node_key, executor: Executor.address_for(@agent)
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      claimed.value.claim_token
    end

    def commit_tool(task, content:, outcome: "completed", is_error: false, structured_content: nil)
      committed = Executors::Commit.call(Executors::Commit::Command.new(
        run: task.run, task_key: task.node_key, executor: Executor.address_for(@agent),
        claim_token: claim_tool(task), content: content, structured_content: structured_content,
        result_type: nil, outcome: outcome, is_error: is_error, title: nil, metadata: nil
      ))
      assert_predicate committed, :applied?, committed.outcome.inspect
    end
end
