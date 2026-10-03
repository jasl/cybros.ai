require "test_helper"

# A compose call whose script places steps the kernel cannot see — after an `await`, or none at all —
# answers the call with the evaluator's refusal and appends nothing: the model reads why, at once,
# rather than a success receipt for a graph that lost its steps.
class AgentLoops::Compose::UnseenStepsTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(accounts(:cybros))
  end

  test "a script that awaits, or places no step, is refused with its sentence and nothing is appended" do
    {
      '(async () => { g.model({ key: "first", prompt: "p" }); await null; g.model({ key: "lost", prompt: "q" }); })();' =>
        Nexus::Compose::Evaluator::DEFERRED,
      'async function main() { await agent("x"); } main();' => Nexus::Compose::Evaluator::NO_STEP,
    }.each do |script, sentence|
      agent_loop = seed(model("round1", "tools" => [Nexus::Compose::DEFINITION]))
      start!(agent_loop)
      run_loop_round!(agent_loop, sse_success("composing", tool_calls: [
        { id: "call_c", name: "compose", arguments: { script: script, wait: true }.to_json },
      ]))
      call = loop_node(agent_loop, "r1t0")
      AgentLoops::ComposeJob.perform_now(call.id)

      assert call.reload.output_summary["is_error"], script
      assert_includes call.output_body.effective_text, "script_error: #{sentence}", script
      assert_equal %w[r1 r1t0 round1], agent_loop.agent_loop_nodes.pluck(:node_key).sort, script
    end
  end

  private

    def start!(agent_loop)
      assert_predicate AgentLoops::Start.call(AgentLoops::Start::Command.new(
        agent_loop: agent_loop, acting_user: @human
      )), :accepted?
      schedule_loop!(agent_loop)
    end
end
