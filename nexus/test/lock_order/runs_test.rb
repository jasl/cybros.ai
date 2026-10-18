require "test_helper"
require_relative "../test_helpers/lock_order_test_helper"

class RunsLockOrderTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  test "image publication pins its upload creator before the run and invocation" do
    creator = users(:member)
    created = create_loop(model("picture", "workload" => "image_generation", "model" => { "model" => "dev/mock-image" }),
      workspace: workspaces(:shared), creating_user: creator, default_runner_executor_public_id: nil)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: creator))
    Runs::ScheduleReady.call(run_id: run.id)
    ModelInvocations::AdmitQueuedWork.call
    invocation = run.tasks.sole.selected_model_invocation
    apply_via(invocation.attempts.last, json_response(200, {
      "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    }))
    sequences = assert_ladder_order("image task publication") do
      assert_equal 1, Runs::ConvergeTerminalSteps.call(invocation_id: invocation.id)[:recorded]
    end
    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[users runs model_invocations content_fragments event_cursors]
    assert_equal 1, run.tasks.sole.output_body.content_uploads.count
  end

  # The loop plane's own converger, and the flow that pins its two new
  # ranks at once: the loop row is the graph's universal lane lock, the
  # step invocation is locked under it, and the narration cursor comes
  # LAST. Cancel runs the same three tables in the same order (its
  # in-flight terminalizations deliberately precede any narration), so the
  # ABBA those two would otherwise complete cannot exist.
  test "the loop step converger descends loop, invocation, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    run, node = create_task(account: account, creator: human)
    ModelInvocation.where(id: node.selected_model_invocation_id)
      .update_all(status: "failed", failure_reason_key: "probe")

    sequences = assert_ladder_order("loop step converger") do
      assert_equal 1, Runs::ConvergeTerminalSteps.call[:recorded]
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[runs model_invocations event_cursors]
    assert_equal "failed", run.reload.tasks.sole.status
  end

  # The regression shape: a pass that FAILS one ready task and MINTS another takes the event cursor
  # (ladder tail) and then reaches back down for content fragments. Narration is buffered to the end
  # of the transaction precisely so this flow cannot invert; drive it here so the guard, not
  # intuition, is what says so.
  test "a mixed schedule pass seals fragments before it ever takes the cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(parallel(tool("probe"), model("step", "prompt" => "go")), model("after"),
      workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: human
    ))

    sequences = assert_ladder_order("mixed schedule pass") do
      Runs::ScheduleReady.call(run_id: run.id)
    end

    seen = sequences.flatten
    assert_includes seen, "content_fragments"
    assert_includes seen, "event_cursors"
    assert_equal "dispatched", run.tasks.find_by(node_key: "probe").status,
      "the tool parks on its runner"
    assert_equal "running", run.tasks.find_by(node_key: "step").status
  end

  # The await door is the first flow to lock a task row explicitly, so it
  # is driven here rather than trusted: loop, then task, then the cursor
  # its narration takes.
  test "an await resolution descends loop, task, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(ask("gate"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(
      run: run, acting_user: human
    ))
    Runs::ScheduleReady.call(run_id: run.id)
    gate = run.tasks.sole.reload

    sequences = assert_ladder_order("await resolution") do
      result = Runs::Parks::Settle.call(
        node: gate, claim_token: gate.resolution_token, content: "answered"
      )
      assert_predicate result, :applied?
    end

    # The content write sits between the task and the cursor, which is
    # ladder-correct; what this pins is the ORDER of the three new ranks.
    seen = sequences.flatten
    assert_operator seen.index("runs"), :<, seen.index("tasks")
    assert_operator seen.index("tasks"), :<,
      seen.index("event_cursors")
  end

  # The executor claim: loop, then the one task it grants — the executor and workspace reads are
  # lock-free, so `executors` (ranked BEFORE `runs`) never appears after the loop.
  test "the executor claim descends loop then task, never the executor row" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: human))
    Runs::ScheduleReady.call(run_id: run.id)

    sequences = assert_ladder_order("executor claim") do
      result = Executors::Claim.call(Executors::Claim::Command.new(
        run: run, task_key: "probe", executor: suite_runner
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
    end

    seen = sequences.flatten
    assert_operator seen.index("runs"), :<, seen.index("tasks")
    assert_not_includes seen, "executors"
  end

  # Selecting a default mutates the host preference and event only. A
  # hosted Run's accepted tasks require no lock or readdress pass.
  test "a hosted default change locks the conversation and cursor without touching accepted tasks" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human,
      default_runner_executor: suite_runner)
    seam = create_run_backed_turn(conversation: conversation, acting_user: human)
    grown = grow(seam.run, tool("probe"))
    assert_predicate grown, :applied?
    Runs::ScheduleReady.call(run_id: seam.run.id)
    task = seam.run.tasks.find_by!(node_key: "probe")
    assert_equal "dispatched", task.status
    before = task.attributes
    other = connect_runner(manager: users(:owner), registration_identifier: "new-default",
      display_name: "Selected", assignment_scope: :account_wide).executor_access_token.executor
    other.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS)

    sequences = assert_ladder_order("default selection") do
      result = Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
        host: conversation, executor_public_id: other.public_id, acting_user: human
      ))
      assert_equal :accepted, result.outcome, result.detail.to_s
    end

    assert_equal 1, sequences.length, sequences.inspect
    assert_equal %w[conversations event_cursors], sequences.sole.uniq
    assert_not_includes sequences.flatten, "runs"
    assert_not_includes sequences.flatten, "tasks"
    assert_not_includes sequences.flatten, "executors"
    assert_equal other.id, conversation.reload.default_runner_executor_id
    assert_equal before, task.reload.attributes
  end

  test "a standalone default change locks the Run and cursor without touching accepted tasks" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: human))
    Runs::ScheduleReady.call(run_id: run.id)
    task = run.tasks.find_by!(node_key: "probe")
    before = task.attributes
    other = connect_runner(manager: users(:owner), registration_identifier: "new-default",
      display_name: "Selected", assignment_scope: :account_wide).executor_access_token.executor
    other.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS)

    sequences = assert_ladder_order("standalone default selection") do
      result = Executors::DefaultRunner.call(Executors::DefaultRunner::Command.new(
        host: run, executor_public_id: other.public_id, acting_user: human
      ))
      assert_equal :accepted, result.outcome, result.detail.to_s
    end

    assert_equal 1, sequences.length, sequences.inspect
    assert_equal %w[runs event_cursors], sequences.sole.uniq
    assert_not_includes sequences.flatten, "tasks"
    assert_not_includes sequences.flatten, "executors"
    assert_equal other.id, run.reload.default_runner_executor_id
    assert_equal before, task.reload.attributes
  end

  # The executor commit: the three fences are lock-free reads before
  # Settle's loop lock; then loop, task, and the cursor its narration takes.
  test "the executor commit descends loop, task, cursor" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: human))
    Runs::ScheduleReady.call(run_id: run.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "probe", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?

    sequences = assert_ladder_order("executor commit") do
      result = Executors::Commit.call(Executors::Commit::Command.new(
        run: run, task_key: "probe", executor: suite_runner,
        claim_token: claimed.value.claim_token, content: "answered", structured_content: nil,
        result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?
    end

    seen = sequences.flatten
    assert_operator seen.index("runs"), :<, seen.index("tasks")
    assert_operator seen.index("tasks"), :<, seen.index("event_cursors")
    assert_not_includes seen, "executors"
  end

  # THE COMMIT CARRYING A `resource_link`: the linked capture is resolved and pinned `FOR KEY SHARE`
  # BETWEEN the loop lock and the node lock — `content_uploads` sits below `runs` and above
  # `tasks`, the rung every input door already drives — and the body writer then binds it
  # under the same order.
  test "the executor commit carrying a resource_link pins the capture between the loop and the task" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    created = create_loop(tool("probe"), workspace: workspaces(:shared), creating_user: human)
    assert_predicate created, :created?
    run = created.run
    Runs::Start.call(Runs::Start::Command.new(run: run, acting_user: human))
    Runs::ScheduleReady.call(run_id: run.id)
    claimed = Executors::Claim.call(Executors::Claim::Command.new(
      run: run, task_key: "probe", executor: suite_runner
    ))
    assert_predicate claimed, :accepted?
    capture = account.content_uploads.create!(
      creating_executor: suite_runner,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("lock-order-capture"), filename: "capture.png", content_type: "image/png"
      )
    )

    sequences = assert_ladder_order("executor commit with a capture") do
      result = Executors::Commit.call(Executors::Commit::Command.new(
        run: run, task_key: "probe", executor: suite_runner,
        claim_token: claimed.value.claim_token,
        content: [{ "type" => "text", "text" => "saved" },
                  { "type" => "resource_link", "uri" => "nexus://uploads/#{capture.public_id}", "name" => "capture.png" }],
        structured_content: nil, result_type: nil, outcome: "completed", is_error: false, title: nil, metadata: nil
      ))
      assert_predicate result, :applied?
    end

    seen = sequences.flatten
    assert_includes seen, "content_uploads", "the commit pins the capture it binds"
    %w[runs content_uploads tasks content_fragments].each_cons(2) do |above, below|
      assert_operator seen.index(above), :<, seen.index(below),
        "the commit descends #{above} before #{below}: #{seen.inspect}"
    end
    assert_not_includes seen, "executors"
  end

  test "loop cancel terminalizes its steps before it narrates" do
    account = accounts(:cybros)
    DevModelLane.ensure_enabled!(account)
    human = users(:member)
    run, = create_task(account: account, creator: human)

    sequences = assert_ladder_order("loop cancel") do
      result = Runs::Stop.call(Runs::Stop::Command.forced(
        run: run, acting_user: human
      ))
      assert_predicate result, :accepted?
    end

    collapsed = sequences.map { |tables| tables.chunk_while { |a, b| a == b }.map(&:first) }
    assert_includes collapsed, %w[runs model_invocations event_cursors]
  end
end
