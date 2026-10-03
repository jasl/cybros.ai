require "delegate"

# Terminal apply: what the send came back with, applied to the rows.
#
# Every case here drives the REAL chain — acceptance, admission, the start
# claim — and fakes only the adapter, because the subject is what lands on
# the rows and hand-built rows are how two shipped bugs stayed invisible.
module InvocationResultTestHelper
  extend ActiveSupport::Concern

  included do
    include InvocationHarness

    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      DevModelLane.ensure_enabled!(@account)
    end
  end

  # Every exit writes the receipt (item 3): the assertions on each path
  # below use this to say so, because the wiring is five call sites and a
  # mutation deleting any one of them must fail a test, not pass silently.
  def receipt_for(attempt)
    UsageRecord.find_by(
      model_invocation_public_id: attempt.model_invocation.public_id,
      attempt_ordinal: attempt.ordinal
    )
  end

  private

    # An Anthropic answer over the fake adapter, the lane whose finish and
    # refusal carry the most facts; `body` overrides the defaults.
    def anthropic_answer(body)
      SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_123", "stop_reason" => "end_turn",
          "usage" => { "input_tokens" => 2, "output_tokens" => 5 },
        }.merge(body)))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
    end

    def outcome_for_error(error, profile:)
      ModelInvocations::Dispatch::Result.new(
        outcome: ModelInvocations::Dispatch::SENT,
        result: nil, error: error, timing: nil, profile: profile, request_id: nil
      )
    end

    # `adapter_profile` names the wire the result came from when the
    # classifier reads it (the finish table is per wire); nil keeps the
    # dev lane's.
    def apply_provider_result(attempt, provider_result, adapter_profile: nil)
      started = start(attempt)
      built = build(attempt)
      outcome = fake_dispatch(sse_success("placeholder")) do
        ModelInvocations::Dispatch.call(
          attempt: started.attempt, context: started.context, request: built.request
        )
      end
      patched = SimpleDelegator.new(outcome)
      patched.define_singleton_method(:result) { provider_result }
      if adapter_profile
        profile = SimpleDelegator.new(outcome.profile)
        profile.define_singleton_method(:adapter_profile) { adapter_profile }
        patched.define_singleton_method(:profile) { profile }
      end

      ModelInvocations::ApplyResult.call(attempt: started.attempt, outcome: patched)
    end
end
