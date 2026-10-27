require "test_helper"
require_relative "../../test_helpers/lock_order_test_helper"

class Runs::SpawnOperationsTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper
  include LockOrderTestHelper

  PROGRAM_TOOL = {
    "type" => "function",
    "function" => { "name" => "program", "parameters" => { "type" => "object" } },
  }.freeze

  setup do
    @human = users(:member)
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!
    declare_tools!(@agent, tools: [PROGRAM_TOOL, Nexus::Tools::SPAWN, READ_TOOL])
    @agent.update!(delegation_catalog: [{ "name" => "reviewer", "description" => "Review the task",
      "model_mode" => "caller", "declaration" => { "tool_definitions" => [READ_TOOL], "approval_mode" => "bypass" } }])
    @executor = Executor.address_for(@agent)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "a waited turn-owned spawn is observed and lets its original program finish" do
    program = start_program
    token = program.claim_token
    spawn = submit_spawn(program)
    assert_ladder_order("prepare a waited turn-owned spawn") { run_spawn(spawn) }
    assert_nil observe(program).fetch("observation")

    child = spawn.reload.spawned_conversation
    assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: child.id)
    child_run = child.turns.sole.active_variant.run
    schedule_loop!(child_run)
    run_loop_round!(child_run, sse_success("Review complete."))
    assert_predicate child_run.reload, :delivered?
    Runs::Spawn::Relay.call(conversation_id: child.id)

    observed = observe(program).fetch("observation")
    assert_not_nil observed, "the completed child's report must release the waiting program"
    assert_equal "completed", observed.dig("outcome", "status")
    assert_equal "Mock: Review complete.", observed.dig("outcome", "output")
    assert_equal token, program.reload.claim_token
    assert_equal "dispatched", program.status
    assert_predicate commit(program, "Program used the review."), :applied?
    schedule_loop!(program.run)
    run_loop_round!(program.run, sse_success("Final answer after review."))
    assert_predicate program.run.reload, :delivered?
    assert_empty @conversation.inputs.reload
  end

  test "a refused completion leaves no await or child input behind" do
    _turn, run = materialize_loop_reply!(@conversation, agent: @agent)
    key = "s" * 52
    appended = Runs::Tasks::Append.call(Runs::Tasks::Append::Command.kernel(
      run: run, tip: Runs::Tasks::Append.boundary_tip(run), origin: "author",
      steps: [Runs::Tasks::Step::Tool.new(key: key, name: "spawn", input: {
        "declaration" => "reviewer", "prompt" => "Review the supplied task.", "wait" => true, "lifetime" => "turn",
      })]
    ))
    assert_predicate appended, :applied?, appended.outcome.inspect
    schedule_loop!(run)
    run_loop_round!(run, sse_success("Dispatch the authored review."))
    spawn = loop_node(run, key)
    # The authored key and its await key fit; the longer completion key is
    # refused by the real compiler after the await has been prepared.
    assert_ladder_order("roll back a refused spawn completion") do
      Runs::ConversationToolJob.perform_now(spawn.id)
    end
    schedule_loop!(run)

    assert_equal true, spawn.reload.output_summary.fetch("is_error")
    assert_includes spawn.output_body.effective_text, "delegation_canceled"
    assert_nil spawn.spawned_conversation
    assert_empty Conversation.where(parent_conversation_id: @conversation.id)
    assert_nil spawn.spawn_await
    assert_nil spawn.spawn_delegation
    assert_predicate run.reload, :delivered?
  end

  private

    def start_program
      _turn, run = materialize_loop_reply!(@conversation, agent: @agent)
      schedule_loop!(run)
      run_loop_round!(run, sse_success("Review using the program", tool_calls: [
        { id: "program_call", name: "program", arguments: "{}" },
      ]))
      program = run.tasks.find_by!(tool_call_id: "program_call")
      claimed = Executors::Claim.call(Executors::Claim::Command.new(
        run: run, task_key: program.node_key, executor: @executor
      ))
      assert_predicate claimed, :accepted?, claimed.outcome.inspect
      claimed.value
    end

    def access(program)
      Executors::TaskOperations::Access.new(run: program.run, task_key: program.node_key,
        executor: @executor, claim_token: program.claim_token)
    end

    def submit_spawn(program)
      submitted = Executors::TaskOperations::Submit.new(access: access(program), key: "review",
        request: { "kind" => "tool", "name" => "spawn", "input" => {
          "declaration" => "reviewer", "prompt" => "Review the supplied task.", "wait" => true, "lifetime" => "turn",
        } }).call
      assert_predicate submitted, :accepted?, submitted.outcome.inspect
      assert_nil submitted.value.dig("operation", "refusal")
      program.run.tasks.find_by!(node_key: submitted.value.dig("operation", "receipt", "task_keys").sole)
    end

    def run_spawn(spawn)
      perform_enqueued_jobs(only: [Runs::ConversationToolJob, Runs::ScheduleJob]) do
        Runs::ScheduleReady.call(run_id: spawn.run_id)
      end
    end

    def observe(program)
      observed = Executors::TaskOperations::Observe.new(access: access(program),
        after: Executors::TaskOperations::Trace.position(program)).call
      assert_predicate observed, :accepted?, observed.outcome.inspect
      observed.value
    end

    def commit(program, content)
      Executors::Commit.call(Executors::Commit::Command.new(run: program.run,
        task_key: program.node_key, executor: @executor, claim_token: program.claim_token,
        content: content, structured_content: nil, result_type: nil, outcome: "completed",
        is_error: false, title: nil, metadata: nil))
    end
end
