require_relative "test_helper"

class ToolsTest < Minitest::Test
  include T3Test

  # The kernel accepted the ask; only its HTTP response was lost. The real
  # claim bridge must let that infrastructure failure reach TaskRun's failed
  # outcome so Nexus can close the still-unobserved child.
  class LostQuestionResponse
    attr_reader :trace

    def initialize = @trace = []

    def operations(claim_token:)
      raise CybrosAgent::TransportError, "response lost after acceptance" unless @trace.empty?

      CybrosAgent::Api::TaskOperations.new(
        context: CybrosAgent::Api::OperationContext.new(tools: [], model_defaults: {}),
        trace: @trace.dup, position: @trace.length
      )
    end

    def submit(key:, request:, claim_token:)
      @trace << CybrosAgent::Api::OperationEvent.new(type: "operation", position: 1,
        key: key, request: request, receipt: { "task_keys" => ["native-question"] })
      raise CybrosAgent::TransportError, "response lost after acceptance"
    end
  end

  def test_lost_question_acceptance_is_not_returned_as_a_completed_tool_error
    Dir.mktmpdir do |root|
      task = LostQuestionResponse.new
      orchestration = Rho::Runner::ClaimOrchestration.new(task: task, claim_token: "exact-claim", log: nil)
      context = Rho::Runner::ExecutionContext.new(orchestration: orchestration,
        run_public_id: "run", conversation_public_id: "conversation", task_key: "coding",
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
      session = T3Test::Session.new(T3Test::Store.new, context)
      native = T3Test::Native.new
      native.question
      factory = ->(env) { Rho::T3::Work.new(settings: settings, session: session, env: env, home: nil, bridge: native) }
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(root, "artifacts"))
      tool = Rho::T3::Tools.delegate(factory).new(env: env)
      pool = Rho::Runner::Pool.new(worker_threads: 1)

      error = nil
      result = begin
        pool.run(pool.reserve, context) { tool.call("prompt" => "Fix the parser") }
      rescue CybrosAgent::TransportError => caught
        error = caught
        nil
      end
      assert_equal ["operation"], task.trace.map(&:type), "the accepted question has not been observed"
      assert_equal "ask", task.trace.first.request.fetch("kind")
      stops = native.calls.map(&:last).select { |params| params["type"] == "run.interrupt" }
      assert_equal 1, stops.length
      assert_equal "native-run", stops.first.fetch("runId")
      assert stops.first.fetch("holdQueue")
      refute native.calls.any? { |_, params| params["type"] == "runtime-request.respond" }
      refute_nil error, "the infrastructure failure became a completed result: #{result.inspect}"
      assert_match "response lost after acceptance", error.message
    ensure
      pool&.stop
    end
  end

  def test_native_policy_refusal_remains_a_tool_error_result
    with_work do |work, native|
      native.document.fetch("thread")["runtimeMode"] = "full-access"
      tool = Rho::T3::Tools.delegate(->(_env) { work }).new(env: nil)
      result = tool.call("prompt" => "Fix the parser")

      assert result.is_error
      assert_match "native permission mode changed", result.content
      assert native.calls.any? { |_, params| params["type"] == "run.interrupt" }
    end
  end
end
