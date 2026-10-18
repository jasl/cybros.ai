require "test_helper"
require_relative "../test_helpers/awaits_test_helper"

class RunsConsoleTest < ActionDispatch::IntegrationTest
  include AwaitsTestHelper

  setup { sign_in_as @human }

  test "run overview, task and graph pages stay bounded and use task keys" do
    run = seed(*30.times.map { |index| ask("gate#{index.to_s.rjust(2, "0")}") })
    token = run.tasks.first.resolution_token
    get run_path(run)
    assert_response :success
    assert_select "a[href=?]", run_tasks_path(run, return_to: workspace_runs_path(run.workspace))
    assert_not_includes response.body, token
    get run_tasks_path(run), params: { limit: 10 }
    assert_response :success
    assert_select "tr[data-task-key]", 10
    assert_not_includes response.body, token
    assert_select "a", text: "Next page", count: 1
    get run_graph_path(run), params: { limit: 5 }
    assert_response :success
    assert_select "li[data-task-key]", 5
    assert_select "svg[role=img] rect", 5
    assert_select "svg path[marker-end]", 4
    get run_task_path(run, "gate00")
    assert_response :success
    assert_not_includes response.body, token
    assert_select "textarea[name=answer]", 0
    get run_tasks_path(run), params: { limit: 101 }
    assert_response :bad_request
    get run_tasks_path(run), params: { after: "invalid" }
    assert_response :bad_request
  end

  test "a reader can inspect but not command and concealed and deleted runs are absent" do
    conversation = Conversation.create!(workspace: @workspace, creating_user: users(:owner), access_default: "read")
    seam = create_run_backed_turn(conversation: conversation, acting_user: users(:owner))
    get run_path(seam.run)
    assert_response :success
    assert_select "form[action*='/pause']", 0
    post run_pause_path(seam.run)
    assert_response :forbidden
    conversation.update!(access_default: "none")
    [run_path(seam.run), run_tasks_path(seam.run), run_graph_path(seam.run)].each do |path|
      get path
      assert_response :not_found
    end
    run = seed(ask("gate"))
    run.update!(tombstoned_at: Time.current)
    get run_path(run)
    assert_response :not_found
    sign_out
    get run_path(seam.run)
    assert_redirected_to new_session_path(return_to: run_path(seam.run))
  end

  test "graph dependencies that skip a level remain visible outside intervening nodes" do
    run = seed(ask("first"), ask("middle"), ask("last", "after" => ["first"]))
    get run_graph_path(run)

    assert_response :success
    assert_select "svg path[marker-end]", 3
    svg = response.parsed_body.at_css("svg[role=img]")
    skip_path = svg.css("path[marker-end]").find { |path| path["d"].include?(" H ") }
    assert skip_path, "the direct first-to-last dependency needs a route outside the middle node"
    gutter = skip_path["d"].match(/ H (\d+) /)[1].to_i
    rightmost_node = svg.css("rect").map { |rect| rect["x"].to_i + rect["width"].to_i }.max
    assert_operator gutter, :>, rightmost_node
    assert_operator svg["width"].to_i, :>, gutter
    assert_select "li[data-task-key=last] a", text: "first", count: 1
  end

  test "pruned execution keeps its overview but all detail and command doors return gone" do
    run = seed(ask("gate"))
    run.update!(details_pruned_at: Time.current)
    get run_path(run)
    assert_response :success
    assert_includes response.body, I18n.t("runs_console.details_pruned")
    [run_tasks_path(run), run_task_path(run, "gate"), run_transcript_path(run), run_graph_path(run),
      run_task_request_path(run, "gate")].each do |path|
      get path
      assert_response :gone
    end
    post run_stop_path(run)
    assert_response :gone
  end

  test "pause resume and stop use the existing lifecycle and preserve filtered return path" do
    run = seed(ask("gate"))
    start!(run)
    return_to = workspace_runs_path(@workspace, status: "running")
    post run_pause_path(run), params: { return_to: return_to }
    assert_response :see_other
    assert_redirected_to run_path(run, return_to: return_to)
    assert_predicate run.reload, :paused?
    post run_resume_path(run)
    assert_response :see_other
    assert_predicate run.reload, :running?
    post run_stop_path(run)
    assert_response :see_other
    assert_predicate run.reload, :stopped?
  end

  test "only a model ask accepts a human answer and records who answered" do
    run = seed(model("round1", "tools" => [Nexus::Tools::ASK]))
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: @human))
    question = ask_through_the_model!(run)
    get run_task_path(run, question.node_key)
    assert_response :success
    assert_select "textarea[name=answer]", 1
    post run_task_resolution_path(run, question.node_key), params: { answer: "The blue one" }
    assert_response :see_other
    assert_equal "completed", question.reload.status
    assert_equal "The blue one", question.content_bodies.find_by!(role: "output").effective_text
    event = run.event_items.where(item_type: "task_status").where("payload ->> 'task_key' = ?", question.node_key).order(:id).last
    assert_includes event.payload.to_json, @human.public_id

    authored = seed(ask("private"))
    start!(authored)
    post run_task_resolution_path(authored, "private"), params: { answer: "No", resolution_token: authored.tasks.sole.resolution_token }
    assert_response :conflict
    assert_equal "dispatched", authored.tasks.sole.status
  end

  test "approval and denial record the human decision through existing commands" do
    build_held = ->(key) do
      run = seed(tool(key, "read_file"), approval_mode: "ask",
        approval_rules: [{ "tool" => "read_file", "verdict" => "ask", "origin" => "author" }])
      start!(run)
      assert_equal "needs_approval", run.tasks.sole.status
      run
    end
    run = build_held.call("approve_me")
    get run_task_path(run, "approve_me")
    assert_response :success
    assert_select "button", text: I18n.t("runs_console.approve"), count: 1
    post run_task_approve_path(run, "approve_me")
    assert_response :see_other
    assert_equal "dispatched", run.tasks.sole.status
    assert_equal @human.id, run.tasks.sole.approved_by_user_id
    post run_task_approve_path(run, "approve_me")
    assert_response :conflict

    denied = build_held.call("deny_me")
    post run_task_deny_path(denied, "deny_me")
    assert_response :see_other
    assert_equal "approval_denied", denied.tasks.sole.error_key
    assert_equal @human.id, denied.tasks.sole.approved_by_user_id
  end

  test "unresolved failure offers retry and abandon while absorbed failures do not" do
    run = seed(ask("gate", "on_failure" => "halt"))
    start!(run)
    gate = run.tasks.sole
    assert_predicate resolve!(gate, outcome: "failed"), :applied?
    get run_task_path(run, gate.node_key)
    assert_response :success
    assert_select "form[action*='/retry']", 1
    post run_task_retry_path(run, gate.node_key)
    assert_response :see_other
    assert_equal "queued", gate.reload.status
    assert_equal 1, gate.execution_generation
    Runs::ScheduleReady.call(run_id: run.id)
    assert_predicate resolve!(gate.reload, outcome: "failed"), :applied?
    post run_task_abandon_path(run, gate.node_key)
    assert_response :see_other
    assert_equal "abandoned", gate.reload.failure_resolution
    get run_task_path(run, gate.node_key)
    assert_response :success
    assert_select "form[action*='/retry']", 0
  end

  test "transcript and sealed model request are separate reads with escaped content" do
    run = seed(model("round1", "prompt" => "<script>read me</script>", "instructions" => "Only the sealed request"), model("later"))
    start!(run)
    get run_transcript_path(run)
    assert_response :success
    assert_select "article[data-task-key]", 2
    get run_task_request_path(run, "round1")
    assert_response :success
    assert_includes response.body, "Only the sealed request"
    assert_select "script", text: "read me", count: 0
    get run_task_request_path(run, "later")
    assert_response :not_found
  end
end
