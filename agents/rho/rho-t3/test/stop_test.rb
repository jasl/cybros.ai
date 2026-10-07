require_relative "test_helper"

class StopTest < Minitest::Test
  include T3Test

  class WaitingQuestion
    attr_reader :submitted

    def initialize
      @submitted = Thread::Queue.new
      @trace = []
    end

    def operations(claim_token:)
      CybrosAgent::Api::TaskOperations.new(
        context: CybrosAgent::Api::OperationContext.new(tools: [], model_defaults: {}),
        trace: @trace.dup, position: @trace.length)
    end

    def submit(key:, request:, claim_token:)
      event = CybrosAgent::Api::OperationEvent.new(type: "operation", position: 1,
        key: key, request: request, receipt: { "task_keys" => ["question"] })
      @trace << event
      @submitted << true
      event
    end

    def observe(after:, claim_token:)
      CybrosAgent::Api::OperationRead.new(observation: nil, position: 1)
    end
  end

  def test_stop_cancels_the_saved_owner_while_its_question_is_waiting
    Dir.mktmpdir do |root|
      task = WaitingQuestion.new
      orchestration = Rho::Runner::ClaimOrchestration.new(task: task, claim_token: "original", log: nil)
      context = Rho::Runner::ExecutionContext.new(run_public_id: "original-run", conversation_public_id: "conversation",
        task_key: "delegate", orchestration: orchestration, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
      store, native = T3Test::Store.new, T3Test::Native.new
      native.question(kind: "user_input")
      env = Rho::Runner::ToolEnv.new(root: root, artifacts_dir: File.join(root, "artifacts"))
      work = Rho::T3::Work.new(settings: settings, session: T3Test::Session.new(store, context), env: env, home: nil, bridge: native)
      pool = Rho::Runner::Pool.new(worker_threads: 1)
      ended = Thread::Queue.new
      owner = Thread.new do
        pool.run(pool.reserve, context) { work.delegate("prompt" => "Fix the fixture") }
        ended << :returned
      rescue Rho::Runner::ExecutionContext::Cancelled
        ended << :canceled
      end
      assert task.submitted.pop(timeout: 2), "the original question was never submitted"

      controller_context = Rho::Runner::ExecutionContext.new(run_public_id: "control-run", conversation_public_id: "conversation", task_key: "stop")
      session = T3Test::Session.new(store, controller_context)
      session.on_cancel = -> { context.cancel(:canceled) }
      controller = Rho::T3::Work.new(settings: settings, session: session, env: env, home: nil, bridge: native)
      result = Rho::Runner::ExecutionContext.with(controller_context) do
        controller.control("action" => "stop", "work_id" => store.rows.keys.first)
      end

      refute result.is_error
      assert_equal [{ "run" => "original-run", "task" => "delegate" }], session.cancellations
      assert_equal :canceled, ended.pop(timeout: 2), "the original delegation stayed inside its question wait"
      refute controller_context.cancelled?
      stops = native.calls.map(&:last).select { |params| params["type"] == "run.interrupt" }
      assert_equal 1, stops.length
      assert_equal "native-run", stops.first.fetch("runId")
      assert stops.first.fetch("holdQueue")
      refute native.calls.any? { |_, params| params["type"] == "runtime-request.respond" }
    ensure
      context&.cancel(:canceled)
      owner&.join(2)
      pool&.stop
    end
  end
end
