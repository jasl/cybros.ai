require "test_helper"

# The execution host end to end, without a network: claim, compile, send —
# and the writer each refusal is answered by.
class ModelInvocations::RunJobTest < ActiveJob::TestCase
  include InvocationHarness
  include LoopLaneTestHelper

  # The dev text lane STREAMS, so the fake answers the way its wire does: SSE
  # events through the block, and a body-less envelope. A JSON answer to a
  # streaming request is a protocol failure, which is what this fake returned
  # before the lane declared its transport — and the send correctly reported
  # `possibly_accepted` for it.
  class FakeAdapter < SimpleInference::HTTPAdapter
    def call_stream(_request)
      return call(_request) unless block_given?

      yield %(data: {"type":"response.output_text.delta","delta":"hi"}\n\n)
      yield %(data: {"type":"response.completed","response":{"id":"resp_1",) +
            %("output":[{"type":"message","role":"assistant",) +
            %("content":[{"type":"output_text","text":"hi"}]}],) +
            %("usage":{"input_tokens":1,"output_tokens":1}}}\n\n)
      yield "data: [DONE]\n\n"
      { status: 200, headers: { "content-type" => "text/event-stream", "x-request-id" => "req_1" },
        body: nil }
    end

    def call(_request)
      { status: 200, headers: { "content-type" => "application/json", "x-request-id" => "req_1" },
        body: JSON.generate({ "id" => "resp_1", "output" => [] }) }
    end
  end

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
  end

  test "it claims, compiles, sends, and records what the client reported" do
    attempt = admitted_attempt

    perform(attempt)

    attempt.reload
    assert_predicate attempt, :started?
    # Terminal apply consumes the send in the same job pass now: the client
    # answered, so the rows say so, and the receipt landed with them.
    assert_equal "completed", attempt.status
    assert_equal "settled", attempt.settlement_state
    receipt = UsageRecord.find_by!(
      model_invocation_public_id: attempt.model_invocation.public_id
    )
    assert_equal "req_1", receipt.provider_request_id
    assert_equal "completed", attempt.model_invocation.reload.status
  end

  # A refusal that ends the work gets the terminal class its cause deserves,
  # so an operator reading several dead ordinals can tell them apart.
  test "a passed deadline terminalizes as timed out" do
    attempt = admitted_attempt
    attempt.update!(deadline_at: 1.minute.ago)

    perform(attempt)

    assert_equal "timed_out", attempt.reload.status
    assert_not_predicate attempt, :started?
    assert_equal "timed_out", attempt.model_invocation.reload.status
  end

  # **THE ORDINAL AND THE INVOCATION END TOGETHER**, and this is the assertion
  # that was missing while they did not. Ending only the Attempt left the
  # parent `running` with nothing on earth able to reach it again — both
  # sweeps scan ACTIVE attempts and this one is terminal, the converger wants
  # an already-terminal parent, and admission destroyed the queue entry. And
  # `running` is not an idle word: it is what the capacity brakes count, so
  # each stranded row permanently consumed one of its owner's sixteen slots.
  test "every pre-IO refusal ends the invocation, not just the ordinal" do
    endings = {
      ->(attempt) { attempt.update!(deadline_at: 1.minute.ago) } => "timed_out",
      ->(attempt) { unseal_input(attempt) } => "failed",
    }

    endings.each do |break_it, expected|
      attempt = admitted_attempt
      break_it.call(attempt)

      perform(attempt)

      invocation = attempt.model_invocation.reload
      assert_predicate invocation, :terminal?,
        "a #{expected} ordinal must not leave its invocation running forever"
      assert_equal expected, invocation.status
      assert_not_nil invocation.failure_reason_key, "and it must record why"
      assert_equal 0, ModelInvocation.where(status: "running").count
    end
  end

  test "an authority cut terminalizes as canceled" do
    attempt = admitted_attempt
    ModelInvocation::Cancellation.call(
      scope: ModelInvocation.where(id: attempt.model_invocation_id), reason: "workspace_archived"
    )

    perform(attempt)

    assert_equal "canceled", attempt.reload.status
    assert_equal "canceled", attempt.model_invocation.reload.status
  end

  # The race this host is designed to lose quietly. Another host holds the
  # work; this job writes nothing at all.
  test "an attempt another host already started is left entirely alone" do
    attempt = admitted_attempt
    invocation = attempt.model_invocation
    winner = ModelInvocations::ProviderStart.call(
      attempt: attempt, host: "model_runner",
      base_url: ModelCatalog.provider_base_url(invocation.provider_id),
      profile: DevModelLane.profile_for_invocation(invocation)
    )

    perform(attempt)

    attempt.reload
    assert_equal "model_runner", winner.context.host
    assert_equal "running", attempt.status
    assert_empty UsageRecord.where(model_invocation_public_id: invocation.public_id),
      "the losing job sent nothing"
  end

  # The worst shape this job can produce, and the one the first version did:
  # a request that cannot be compiled, discovered AFTER the claim, is
  # settleable by nothing — both pre-IO writers refuse a started attempt on
  # purpose. So compiling comes first and its refusal is terminal.
  test "a request that cannot be compiled ends before anything is claimed" do
    attempt = admitted_attempt
    unseal_input(attempt)

    perform(attempt)

    attempt.reload
    assert_not_predicate attempt, :started?, "nothing may be claimed for a request we cannot build"
    assert_equal "failed", attempt.status
    assert_equal "not_applicable", attempt.settlement_state
    assert_not_nil attempt.terminal_at
    # And the budget is intact: an ordinal that never started spends none of it.
    assert_not ModelInvocations::AttemptOrdinal.budget_spent?(
      attempt.model_invocation, ordinal: attempt.ordinal
    )
  end

  # A priced ordinal ends exactly like the free shapes — admission held
  # nothing, so a pre-IO ending has nothing to give back.
  test "an uncompilable priced request terminalizes cleanly" do
    @account.update!(cost_unit: "USD")
    attempt = admitted_attempt(model: DevModelLane::PRICED_TEXT_MODEL)
    unseal_input(attempt)

    perform(attempt)

    assert_equal "failed", attempt.reload.status
    assert_equal "priced", attempt.admission_shape
    assert_equal "not_applicable", attempt.settlement_state
  end

  # THE PERSON SEES THE TOKENS WHICHEVER HOST EXECUTES. This host built no sink at all, so a reply
  # the queue worker claimed narrated NOTHING while the same reply on the reactor host streamed
  # every delta — and which host claims is a race neither the author nor the watcher chooses. The
  # sink is the same object `StreamSink.for` hands the runner, so the assertion is about the feed
  # rather than about the class.
  test "a reply this host executes narrates its deltas on the transcript stream" do
    conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human)
    attempt = reply_attempt(conversation)
    turn = conversation.reload.conversation_turns.order(:position).last

    published = []
    ActionCable.server.stub(:broadcast, ->(stream, payload) { published << [stream.to_s, payload] }) do
      perform(attempt)
    end

    stream = "agent_api:v1:conversation:#{conversation.public_id}:transcript"
    deltas = published
      .select { |name, _| name == stream }
      .map { |_, payload| payload.fetch(:event) }
      .select { |event| event[:type] == "text_delta" }
    assert_not_empty deltas, "the queue host ran the whole reply and said nothing: #{published.inspect}"
    assert_equal "hi", deltas.map { |event| event[:text] }.join
    # ONE ROUTING KEY, the same one the reactor host's deltas carry: a
    # follower routes by the turn whichever host wrote the frame.
    assert_equal [turn.public_id], deltas.map { |event| event[:turn_public_id] }.uniq
  end

  test "a vanished attempt is not an error" do
    assert_nothing_raised do
      ModelInvocations::RunJob.perform_now(SecureRandom.uuid_v7)
    end
  end

  private

    def perform(attempt)
      ModelInvocations::ExecutionAdapter.stub(:for, ->(*) { FakeAdapter.new }) do
        ModelInvocations::RunJob.perform_now(attempt.public_id)
      end
    end

    # A direct reply's attempt, admitted and ready for a host to claim: the
    # hosted plane is where the transcript stream lives.
    def reply_attempt(conversation)
      post_input!(conversation, acting_user: @human, kind: "direct_reply", text: "narrate me",
        provider_id: "dev", model_ref: "mock-text")
      Conversations::Inputs::ApplyNext.drain(conversation_id: conversation.id)
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation.conversation_id == conversation.id
      end
      raise "the reply was not admitted" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end

    # The send reads the Invocation-owned assembled request, never the source
    # OneShot input.
    def unseal_input(attempt)
      attempt.model_invocation.content_bodies.find_by!(role: "request")
        .update_columns(sealed_at: nil)
    end
end
