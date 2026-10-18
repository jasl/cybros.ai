require "test_helper"
require_relative "../../../test_helpers/lock_order_test_helper"

class Runs::ScheduleTool::RunTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include LockOrderTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
    declared = Users::DeclareConfiguration.call(user: @agent,
      tool_definitions: nil, approval_rules: nil, prompt_mechanism: nil, prompt_template: nil,
      kernel_tools: %w[nexus.schedules.read nexus.schedules.manage], approval_mode: "bypass",
      compaction_policy: { "mode" => "kernel", "model" => "dev/mock-unmetered" },
      image_model: "dev/mock-image", default_model: "dev/mock-text", fallback_models: ["dev/mock-unmetered"])
    assert_equal :declared, declared.outcome, declared.user.errors.full_messages.join
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "summarizer", content: "Retain the agreed facts.")
  end

  test "creation captures the calling execution and settles atomically without an application executor" do
    @submitter = @human
    node = tool_call(create_arguments)
    source = node.run
    @agent.update!(image_model: nil, compaction_policy: { "mode" => "off" }, kernel_tools: [],
      fallback_models: [], default_model: "dev/mock-priced")
    PromptDocuments::Write.call(anchor: { user: @agent }, slot: "summarizer", content: "Later prompt.")

    assert_ladder_order("kernel schedule creation") do
      assert_difference -> { @conversation.schedules.count }, 1 do
        assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
        assert_equal :not_running, Runs::ScheduleTool::Run.call(node: node.reload)
      end
    end
    job = @conversation.schedules.sole
    assert_equal @agent, job.creating_user
    assert_equal @agent, job.answering_user
    assert_equal [source.public_id, node.node_key], [job.source_run_public_id, job.source_task_key]
    assert_equal "dev/mock-image", job.agent_configuration.image_model
    assert_equal "Retain the agreed facts.", job.agent_configuration.summarizer.content
    assert_equal "kernel", job.agent_configuration.compaction_policy.fetch("mode")
    assert_equal %w[manage_schedule read_schedules], Nexus::ToolDeclarations.names(job.agent_configuration.tool_definitions)
    assert_equal ["dev/mock-unmetered"], job.fallback_models
    assert_equal job.public_id, output(node).fetch("public_id")

    assert_equal :dispatched, ::Schedules::Dispatch.call(id: job.id, cutoff: job.next_run_at)
    child = job.reload.last_execution_conversation
    assert_equal job.agent_configuration.as_json, child.agent_configuration.as_json
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.reload.active_turn.active_variant.run
    assert_equal "dev/mock-image", child_run.agent_configuration.image_model
    assert_equal "mock-text", child_run.tasks.sole.model_ref
    assert_equal %w[manage_schedule read_schedules], Nexus::ToolDeclarations.names(child_run.tasks.sole.tool_definitions)
  end

  test "settlement failure rolls back creation and the same task can recover" do
    node = tool_call(create_arguments)
    failing = ->(*) { raise "settlement interrupted" }
    assert_no_difference -> { Schedule.count } do
      error = assert_raises(RuntimeError) do
        Runs::KernelTool.stub(:settle, failing) { Runs::ScheduleTool::Run.call(node: node) }
      end
      assert_equal "settlement interrupted", error.message
    end
    assert_equal "running", node.reload.status
    assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
    assert_equal 1, @conversation.schedules.count
  end

  test "a large saved prompt still permits an atomic mutation with a compact tool receipt" do
    saved = execute(create_arguments)
    job = Schedule.find_by!(public_id: saved.fetch("public_id"))
    # The member API may save a prompt below the input bound whose JSON-shaped
    # tool result crosses the result-body bound after the second string encoding.
    job.update!(prompt: '"' * 300_000)
    version = job.lock_version
    node = tool_call({ "action" => "pause", "job_id" => job.public_id })

    assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
    assert_predicate job.reload, :paused?
    assert_equal version + 1, job.lock_version
    assert_equal '"' * 300_000, job.prompt
    assert_equal "completed", node.reload.status
    assert_equal({ "public_id" => job.public_id, "status" => "paused",
      "lock_version" => job.lock_version, "next_run_at" => nil }, output(node))
    assert_equal :not_running, Runs::ScheduleTool::Run.call(node: node)
    assert_equal version + 1, job.reload.lock_version
  end

  test "read pages and optimistic edits stay scoped to the calling conversation" do
    first = execute(create_arguments.merge("name" => "First"))
    second = execute(create_arguments.merge("name" => "Second"))
    page = execute({ "action" => "list", "limit" => 1 }, name: "read_schedules")
    assert_equal [first.fetch("public_id")], page.fetch("schedules").map { |row| row.fetch("public_id") }
    assert_equal first.fetch("public_id"), page.fetch("next_after")
    page = execute({ "action" => "list", "limit" => 1, "after" => page.fetch("next_after") }, name: "read_schedules")
    assert_equal [second.fetch("public_id")], page.fetch("schedules").map { |row| row.fetch("public_id") }
    assert_nil page.fetch("next_after")

    changed = execute({ "action" => "update", "job_id" => first.fetch("public_id"),
      "expected_lock_version" => first.fetch("lock_version"), "prompt" => "Updated work." })
    assert_equal "Updated work.", changed.fetch("prompt")
    stale = tool_call({ "action" => "update", "job_id" => first.fetch("public_id"),
      "expected_lock_version" => first.fetch("lock_version"), "prompt" => "Stale work." })
    Runs::ScheduleTool::Run.call(node: stale)
    assert_includes stale.reload.output_body.effective_text, "stale_object"
    assert_equal "Updated work.", Schedule.find_by!(public_id: first.fetch("public_id")).prompt

    missing = tool_call({ "action" => "show", "job_id" => SecureRandom.uuid_v7 }, name: "read_schedules")
    Runs::ScheduleTool::Run.call(node: missing)
    assert_includes missing.reload.output_body.effective_text, "not_found"
  end

  test "an oversized saved schedule read settles an error instead of waiting for timeout" do
    saved = execute(create_arguments)
    job = Schedule.find_by!(public_id: saved.fetch("public_id"))
    job.update!(prompt: '"' * 300_000)

    %w[show list].each do |action|
      node = tool_call({ "action" => action, "job_id" => job.public_id }, name: "read_schedules")
      assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
      assert_equal "completed", node.reload.status
      assert node.output_summary.fetch("is_error")
      assert_includes node.output_body.effective_text, "result_too_large"
    end
    assert_predicate job.reload, :active?
    assert_equal '"' * 300_000, job.prompt
  end

  test "cancel removes a pending occurrence and settles in ladder order" do
    saved = execute(create_arguments)
    job = Schedule.find_by!(public_id: saved.fetch("public_id"))
    assert_equal :dispatched, ::Schedules::Dispatch.call(id: job.id, cutoff: job.next_run_at)
    child = job.reload.last_execution_conversation
    assert_equal 1, child.inputs.count
    node = tool_call({ "action" => "cancel", "job_id" => job.public_id })
    assert_ladder_order("kernel schedule cancel") do
      assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
    end
    assert_predicate job.reload, :canceled?
    assert_empty child.inputs
    assert_equal "canceled", output(node).fetch("status")
    assert_equal :not_running, Runs::ScheduleTool::Run.call(node: node.reload)
  end

  test "stopped calls cannot create a schedule" do
    node = tool_call(create_arguments)
    Runs::Stop.call(Runs::Stop::Command.new(run: @run, acting_user: @agent, force: true))
    assert_no_difference -> { Schedule.count } do
      Runs::ScheduleTool::Run.call(node: node.reload)
    end
  end

  test "expired calls settle without creating a schedule" do
    node = tool_call(create_arguments)
    node.update_columns(await_started_at: 2.days.ago)
    assert_no_difference -> { Schedule.count } do
      Runs::ScheduleTool::Run.call(node: node)
    end
    assert_equal "timed_out", node.reload.status
  end

  private

    def create_arguments
      { "action" => "create", "prompt" => "Check the latest status and report here.",
        "rule" => { "kind" => "interval", "every_seconds" => 60,
          "starts_at" => 5.minutes.from_now.utc.iso8601 } }
    end

    def tool_call(arguments, name: "manage_schedule")
      _turn, @run = materialize_loop_reply!(@conversation, agent: @submitter || @agent) unless @run
      schedule_loop!(@run)
      call_id = SecureRandom.hex(6)
      run_loop_round!(@run, sse_success("Scheduled work", tool_calls: [
        { id: call_id, name: name, arguments: arguments.to_json },
      ]))
      @run.tasks.find_by!(tool_call_id: call_id)
    end

    def execute(arguments, name: "manage_schedule")
      node = tool_call(arguments, name: name)
      assert_equal :applied, Runs::ScheduleTool::Run.call(node: node)
      assert_not node.reload.output_summary["is_error"], node.output_body.effective_text
      output(node)
    end

    def output(node) = JSON.parse(node.reload.output_body.effective_text)
end
