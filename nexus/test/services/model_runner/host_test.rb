require "test_helper"

# The reactor host, driven for real: a Sync block carries the fibers, the
# fake adapter answers the wire, and the chain underneath — build, the start
# claim, dispatch, terminal apply, receipts, durable narration — is the
# production chain untouched.
class ModelRunner::HostTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @host = ModelRunner::Host.new(max_in_flight: 4, shutdown_grace: 0.2, logger: Rails.logger)
  end

  test "the claim selector takes prepared runner-pair text work and nothing else" do
    text = admitted_attempt
    embedding = admitted_attempt(workload: "embedding", model: "dev/mock-embedding",
      input: "embed me")

    claimed = @host.send(:claim_batch)

    assert_includes claimed.map(&:id), text.id
    assert_not_includes claimed.map(&:id), embedding.id,
      "a unary lane's only allowed host is the queue"

    @host.instance_variable_get(:@in_flight)[text.id] =
      ModelRunner::Host::InFlight.new(attempt: text)
    assert_not_includes @host.send(:claim_batch).map(&:id), text.id,
      "in-flight work is not re-claimed"
  end

  # The operator's concurrency knob, pinned after review: the id-exclusion
  # alone satisfies the non-re-claim assertion whatever the capacity math
  # says, so the bound needs its own discriminating fixture.
  test "the claim honors remaining capacity" do
    small = ModelRunner::Host.new(max_in_flight: 2, shutdown_grace: 0.2, logger: Rails.logger)
    first = admitted_attempt
    admitted_attempt(creator: users(:owner))
    small.instance_variable_get(:@in_flight)[first.id] =
      ModelRunner::Host::InFlight.new(attempt: first)

    assert_equal 1, small.send(:claim_batch).length, "one slot left claims one row"

    zero = ModelRunner::Host.new(max_in_flight: 1, shutdown_grace: 0.2, logger: Rails.logger)
    zero.instance_variable_get(:@in_flight)[first.id] =
      ModelRunner::Host::InFlight.new(attempt: first)
    assert_empty zero.send(:claim_batch), "a full host claims nothing"
  end

  test "a fiber runs the whole chain: claim, stream, apply, receipt, narration" do
    attempt = admitted_attempt

    fake_dispatch(sse_success("streamed answer")) do
      Sync do |task|
        @host.send(:spawn_execution, task, attempt)
        task.children.each(&:wait)
      end
    end

    attempt.reload
    assert_equal "completed", attempt.status
    assert_equal "settled", attempt.settlement_state, "the receipt landed"
    assert_empty @host.instance_variable_get(:@in_flight)

    invocation = attempt.model_invocation.reload
    assert_equal "completed", invocation.status
    texts = InferenceRequestEventItem.where(inference_request_id: invocation.inference_request_id, item_type: "text_delta")
      .order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal "Mock: streamed answer", texts.join,
      "the durable narration is the runner's addition over the queue host"
  end

  test "a coalesced tail is settled into the narration before the flip" do
    attempt = admitted_attempt
    frames = [
      %(data: {"type":"response.output_text.delta","delta":"first"}\n\n),
      %(data: {"type":"response.output_text.delta","delta":" second"}\n\n),
      "data: #{JSON.generate(
        "type" => "response.completed",
        "response" => { "id" => "resp_1", "status" => "completed",
          "output" => [{ "type" => "message", "role" => "assistant",
                         "content" => [{ "type" => "output_text", "text" => "first second" }] }],
          "usage" => { "input_tokens" => 2, "output_tokens" => 2 } }
      )}\n\n",
      "data: [DONE]\n\n",
    ]
    behaviour = { sse: frames, status: 200,
                  headers: { "content-type" => "text/event-stream" } }

    fake_dispatch(behaviour) do
      Sync do |task|
        @host.send(:spawn_execution, task, attempt)
        task.children.each(&:wait)
      end
    end

    texts = InferenceRequestEventItem.where(inference_request_id: attempt.model_invocation.inference_request_id,
      item_type: "text_delta").order(:sequence).map { |item| item.payload.fetch("text") }
    assert_equal "first second", texts.join,
      "the second fragment rode the pending tail; losing it is losing replay"
  end

  test "a cut parent's stream is aborted and the row left to the converger" do
    attempt = admitted_attempt
    adapter = SlowStreamAdapter.new

    ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { adapter }) do
      Sync do |task|
        @host.send(:spawn_execution, task, attempt)
        sleep(0.05) until adapter.streaming?

        ModelInvocation::Cancellation.call(
          scope: ModelInvocation.where(id: attempt.model_invocation_id),
          reason: "workspace_archived"
        )
        @host.send(:abort_cut_in_flight)
        task.children.each(&:wait)
      end
    end

    assert_empty @host.instance_variable_get(:@in_flight)
    attempt.reload
    assert_equal "running", attempt.status,
      "the host writes no row; the cut attempt is the post-cut converger's"
    assert_equal "canceled", attempt.model_invocation.reload.status
  end

  # An attempt that completed its own parent must finish enqueueing its post-terminal wakes.
  # Treating its own terminal write as an external cancellation interrupts those enqueues and leaves
  # downstream tasks waiting for the recurring converger.
  test "a tick spares the fiber that settled its own parent and still cuts the kernel's cancel" do
    log = StringIO.new
    host = ModelRunner::Host.new(max_in_flight: 4, shutdown_grace: 0.2,
      logger: ActiveSupport::Logger.new(log))
    finishing = admitted_attempt
    cut = admitted_attempt(creator: users(:owner))
    adapter = SlowStreamAdapter.new
    answered = InvocationHarness::FakeAdapter.new(sse_success("done"))
    held = false
    released = false
    enqueue = InferenceRequests::ConvergeTerminalEventsJob.method(:perform_later)
    hold_owner_wake = lambda do |*args|
      held = true
      sleep(0.01) until released
      enqueue.call(*args)
    end

    # One stub, routed by phase: the finishing attempt is spawned first and
    # answered whole; the cut one is spawned once the first is held.
    wire = ->(*) { held ? adapter : answered }
    InferenceRequests::ConvergeTerminalEventsJob.stub(:perform_later, hold_owner_wake) do
      ModelInvocations::ExecutionAdapter.stub(:for, wire) do
        Sync do |task|
          host.send(:spawn_execution, task, finishing)
          spin_until("the owner wake to be held") { held }
          assert_equal "completed", finishing.model_invocation.reload.status,
            "the parent is terminal by this fiber's own hand; the wakes are still owed"

          host.send(:spawn_execution, task, cut)
          spin_until("the cut stream to open") { adapter.streaming? }
          ModelInvocation::Cancellation.call(
            scope: ModelInvocation.where(id: cut.model_invocation_id),
            reason: "workspace_archived"
          )

          host.send(:tick)

          spin_until("the cut fiber to unwind") { !host.instance_variable_get(:@in_flight).key?(cut.id) }
          released = true
          task.children.each(&:wait)
        end
      end
    end

    assert_empty host.instance_variable_get(:@in_flight)
    assert_includes log.string, "model_runner_execution_aborted attempt=#{cut.public_id}",
      "the kernel's cancel still cuts the stream"
    assert_not_includes log.string, "model_runner_execution_aborted attempt=#{finishing.public_id}",
      "an attempt that settled its own parent is finishing, not cut"
    assert_equal "running", cut.reload.status, "the cut row is the post-cut converger's"
    assert_equal "completed", finishing.reload.status
    wakes = enqueued_jobs.map { |job| job["job_class"] }
    %w[InferenceRequests::ConvergeTerminalEventsJob ModelInvocations::AdmitQueuedWorkJob].each do |job|
      assert_includes wakes, job, "the post-terminal wake #{job} must run; the floor is a minute away"
    end
  end

  test "shutdown drains: the grace lets nothing finish, survivors abort, rows go to the sweep" do
    attempt = admitted_attempt
    adapter = SlowStreamAdapter.new(hold: 30)

    ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { adapter }) do
      Sync do |task|
        @host.send(:spawn_execution, task, attempt)
        sleep(0.05) until adapter.streaming?

        @host.send(:drain_in_flight)
        task.children.each(&:wait)
      end
    end

    assert_empty @host.instance_variable_get(:@in_flight)
    attempt.reload
    assert_equal "running", attempt.status,
      "an interrupted stream is never requeued free — the deadline sweep owns it"
    assert_equal "running", attempt.model_invocation.reload.status
  end

  test "the admission pass self-feeds a standalone runner" do
    result = InferenceRequests::Create.call(
      command: InferenceRequests::Create::Command.new(
        workspace: workspaces(:shared), creating_user: @human,
        workload: "text_generation", submitted: DevModelLane.submission_for("text_generation"),
        configuration: {}, input: [{ "role" => "user", "parts" => [
          { "type" => "text", "text" => "say hi" },
        ] }], upload_public_ids: [], billing_subject: nil, idempotency_key: SecureRandom.uuid
      ),
      port: DevModelLane.port
    )
    invocation = InferenceRequest.find_by!(public_id: result.accepted.fetch("inference_request_public_id"))
      .model_invocation

    Sync { @host.send(:run_admission_pass) }
    clear_enqueued_jobs

    assert_equal "running", invocation.reload.status
    assert_equal 1, invocation.attempts.count
  end

  # A fake whose stream stays open until told otherwise: what an abort has
  # to actually interrupt.
  class SlowStreamAdapter < SimpleInference::HTTPAdapter
    def initialize(hold: 30)
      @hold = hold
      @streaming = false
    end

    def streaming? = @streaming

    def call(_request)
      raise "unary path not expected"
    end

    def call_stream(_request)
      @streaming = true
      yield %(data: {"type":"response.output_text.delta","delta":"partial"}\n\n)
      sleep(@hold)
      yield "data: [DONE]\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream" }, body: nil }
    end
  end
end
