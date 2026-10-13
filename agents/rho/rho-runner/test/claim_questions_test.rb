require "test_helper"

class ClaimQuestionsTest < Minitest::Test
  class Task
    attr_reader :trace, :calls, :requests
    attr_accessor :waiting, :on_observe, :lose_submit, :submit_refusals, :on_submit

    def initialize
      @trace = []
      @calls = []
      @requests = []
      @submit_refusals = []
    end

    def operations(claim_token:)
      @calls << [:operations, claim_token, Thread.current]
      CybrosAgent::Api::TaskOperations.new(
        context: CybrosAgent::Api::OperationContext.new(tools: [], model_defaults: {}), trace: @trace.dup, position: @trace.length
      )
    end

    def submit(key:, request:, claim_token:)
      @calls << [:submit, claim_token, Thread.current]
      @requests << { key: key, request: request, claim_token: claim_token }
      @on_submit&.call
      if code = @submit_refusals.shift
        raise CybrosAgent::Api::Conflict.new("Operation refused", code: code)
      end
      entry = CybrosAgent::Api::OperationEvent.new(type: "operation", position: @trace.length + 1,
        key: key, request: request, receipt: { "task_keys" => ["question"] })
      @trace << entry
      if @lose_submit
        @lose_submit = false
        raise CybrosAgent::TransportError, "response lost after acceptance"
      end
      entry
    end

    def observe(after:, claim_token:)
      @calls << [:observe, claim_token, Thread.current]
      @on_observe&.call
      if @waiting
        CybrosAgent::Api::OperationRead.new(observation: nil, position: @trace.length)
      else
        operation = @trace.find { |event| event.type == "operation" }
        entry = CybrosAgent::Api::OperationEvent.new(type: "observation", key: operation.key,
          position: @trace.length + 1, outcome: { "status" => "completed", "content" => [{ "type" => "text", "text" => "accept" }] })
        @trace << entry
        CybrosAgent::Api::OperationRead.new(observation: entry, position: @trace.length)
      end
    end
  end

  def setup
    @task = Task.new
    @pool = Rho::Runner::Pool.new(worker_threads: 1)
  end

  def teardown = @pool.stop

  def test_questions_use_exact_claim_and_replay_durable_answer_without_second_submission
    first = ask("first")
    second = ask("second")
    assert_equal "accept", first.fetch("content").first.fetch("text")
    assert_equal first, second
    assert_equal 1, @task.calls.count { |call| call.first == :submit }
    assert_equal %w[operation observation], @task.trace.map(&:type)
    assert @task.calls.all? { |call| call.last == Thread.current }, "kernel calls remain on the reactor thread"
    assert_equal %w[first second], @task.calls.map { |call| call[1] }.uniq
  end

  def test_replayed_question_cannot_change_the_prompt_under_its_old_key
    ask("first")
    assert_raises(Rho::Runner::ClaimOrchestration::Failure) { ask("second", prompt: "A different action") }
    assert_equal 1, @task.calls.count { |call| call.first == :submit }
  end

  def test_lost_acceptance_response_is_reconciled_from_its_receipt_under_the_same_claim
    @task.lose_submit = true
    result = ask("first")
    assert_equal "accept", result.fetch("content").first.fetch("text")
    assert_equal 1, @task.calls.count { |call| call.first == :submit }
    assert_equal ["first"], @task.calls.map { |call| call[1] }.uniq
  end

  def test_cancelled_native_wait_does_not_return_a_late_answer
    @task.waiting = true
    context = context("first")
    @task.on_observe = -> { context.cancel(:canceled) }
    assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
      @pool.run(@pool.reserve, context) { context.orchestration.ask(key: "native-question", prompt: "Approve?", options: %w[accept decline]) }
    end
    assert_equal ["operation"], @task.trace.map(&:type)
  end

  def test_a_paused_native_question_waits_then_accepts_the_same_operation_once
    @task.submit_refusals = %w[execution_paused execution_paused]
    result = ask("original-claim")
    assert_equal "accept", result.fetch("content").first.fetch("text")
    assert_equal 3, @task.requests.length
    assert_equal 1, @task.requests.uniq.length, "pause must not change the key, request, or claim"
    assert_equal %w[operation observation], @task.trace.map(&:type)
    assert @task.calls.all? { |call| call.last == Thread.current }
  end

  def test_canceling_a_paused_native_question_stops_before_retrying_submission
    @task.submit_refusals = %w[execution_paused]
    context = context("original-claim")
    @task.on_submit = -> { context.cancel(:canceled) }
    error = assert_raises(Rho::Runner::ExecutionContext::Cancelled) do
      @pool.run(@pool.reserve, context) { context.orchestration.ask(key: "native-question", prompt: "Approve?") }
    end
    assert_equal :canceled, error.reason
    assert_equal 1, @task.requests.length
    assert_empty @task.trace
  end

  def test_claim_loss_or_stop_ends_the_paused_question_without_another_retry
    %w[not_claimant execution_stopped].each do |refusal|
      @task = Task.new
      @task.submit_refusals = ["execution_paused", refusal]
      error = assert_raises(CybrosAgent::Api::Conflict) { ask("original-claim") }
      assert_equal refusal, error.code
      assert_equal 2, @task.requests.length
      assert_empty @task.trace
    end
  end

  private

    def context(token)
      bridge = Rho::Runner::ClaimOrchestration.new(task: @task, claim_token: token, log: nil)
      Rho::Runner::ExecutionContext.new(orchestration: bridge, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5)
    end

    def ask(token, prompt: "Approve?")
      context = context(token)
      @pool.run(@pool.reserve, context) { context.orchestration.ask(key: "native-question", prompt: prompt, options: %w[accept decline]) }
    end
end
