require "test_helper"
require "test_helpers/log_capture"
require "test_helpers/invocation_result_test_helper"
require "test_helpers/gemini_finish_test_helper"

# A DIRECT REPLY A PROVIDER'S CLASSIFIER DECLINED RE-ASKS ONCE ON THE MODEL
# ITS ANSWERER DECLARED. A tool-less reply has no step to requeue, so the
# converger decides — once, under the conversation lock, before anything
# reads the reply as settled — between the stand and the kernel's own
# regeneration: a `fallback` sample beside the refused one, assembled as
# the refused sample's POSTER, the turn held running throughout. A
# fallback sample never falls back again, a content block is never re-sent,
# a model that already declined this turn is never picked, and a person's
# stop in the window wins over a fallback nobody asked for.
class Conversations::Turns::RefusalFallbackTest < ActiveJob::TestCase
  include InvocationResultTestHelper
  include GeminiFinishTestHelper
  include LogCapture

  SWITCH = { "from" => "dev/mock-text", "to" => "dev/mock-unmetered", "reason" => "model_refused",
             "category" => "cyber" }.freeze

  setup do
    @agent = users(:agent)
    @workspace = workspaces(:shared)
    declare!(fallback_model: "dev/mock-unmetered")
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
  end

  test "an abnormal Gemini finish fails the direct reply without a fallback or usable partial" do
    turn = reply!
    apply_provider_result(admitted_attempt, gemini_error_result("OTHER"), adapter_profile: "gemini_generate_content")
    converge!

    variant = turn.reload.active_variant
    assert_equal ["failed", "failed", "provider_error"],
      [turn.status, variant.status, variant.model_invocation.failure_reason_key]
    assert_equal 1, turn.conversation_turn_variants.count
    assert_nil @conversation.reload.active_turn_id
    assert_empty variant.model_invocation.content_bodies.where(role: %w[response reasoning reasoning_trace tool_calls])
    terminal = @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last.payload
    assert_equal ["failed", "error", "provider_error"], terminal.values_at("status", "finish_quality", "failure_reason_key")
    assert_not terminal.key?("model_change")
  end

  test "a refused reply re-asks once on the answerer's fallback, as its poster, the turn held running" do
    turn = reply!
    refused = turn.active_variant
    steer = accept!(text: "and briefly", delivery_mode: "steer")
    assert_equal "steering", steer.state
    mark = last_sequence

    published = []
    lines = capture_log do
      ActionCable.server.stub(:broadcast, ->(stream, payload) { published << [stream.to_s, payload] }) do
        refuse!
        converge!
      end
    end

    assert_equal "failed", refused.reload.status
    assert_equal ["running", refused.id], turn.reload.values_at(:status, :active_variant_id),
      "the turn never went idle; the refused sample stays where it was"
    assert_equal turn.id, @conversation.reload.active_turn_id
    fallback = turn.conversation_turn_variants.order(:position).last
    assert_equal ["fallback", refused.id, "running", "dev", "mock-unmetered"],
      fallback.values_at(:source, :origin_variant_id, :status, :provider_id, :model_ref)
    invocation = fallback.model_invocation
    assert_equal [@human.id, "queued", "mock-unmetered"],
      invocation.values_at(:creating_user_id, :status, :model_ref), "the poster asks again, never the answerer"
    assert_equal({ "kind" => "mainline", "tier" => "1h", "tail" => true }, invocation.request_options.fetch("prompt_cache"))
    assert_equal ["steering", turn.id], steer.reload.values_at(:state, :steering_target_turn_id),
      "a steer stays bound to a turn that never settled"

    # A regeneration's own order — the new sample, then the turn — with the
    # one turn_status naming the declined sample and the switch.
    assert_equal [
      ["turn_variant", { "turn_public_id" => turn.public_id, "variant_public_id" => fallback.public_id,
                         "regenerating" => true }],
      ["turn_status", { "turn_public_id" => turn.public_id, "turn_kind" => "direct_reply",
                        "variant_public_id" => refused.public_id, "status" => "running", "variant_status" => "failed",
                        "failure_reason_key" => "model_refused", "finish_quality" => "refused",
                        "refusal_category" => "cyber", "model_change" => SWITCH }],
    ], items_since(mark).map { |item| [item.item_type, item.payload] }, "one turn_status says the switch"
    assert_empty published.select { |stream, payload| stream.end_with?(":transcript") && payload.dig(:event, :type) == "turn" },
      "no settled snapshot: a follower never sees the turn fail and then run"
    assert_equal ["event=model_fallback conversation=#{@conversation.public_id} turn=#{turn.public_id} " \
                  "from=dev/mock-text to=dev/mock-unmetered reason=model_refused category=cyber\n"],
      lines.grep(/event=model_fallback/)

    apply_via(admitted_attempt, sse_success("the fallback's answer"))
    converge!

    assert_equal ["completed", fallback.id], turn.reload.values_at(:status, :active_variant_id)
    assert_includes fallback.reload.content_preview, "the fallback's answer"
    projection = AgentAPI::ConversationPresenter.turn_snapshot(turn)
    assert_equal "fallback", projection.dig(:active_variant, :source)
    assert_equal refused.public_id, projection.dig(:active_variant, :origin_variant_public_id)
    assert_nil @conversation.reload.active_turn_id
    assert_equal "pending", steer.reload.state, "the steer's target settled at last"
  end

  test "a fallback sample refused again stands, and nothing asks a third time" do
    turn = reply!
    refuse!
    converge!
    fallback = turn.reload.conversation_turn_variants.order(:position).last
    mark = last_sequence

    refuse!
    converge!

    assert_equal 2, turn.reload.conversation_turn_variants.count, "a fallback never falls back"
    assert_equal ["failed", "failed"], [turn.status, fallback.reload.status]
    assert_nil @conversation.reload.active_turn_id, "the lane is idle again"
    assert_equal [{ "turn_public_id" => turn.public_id, "turn_kind" => "direct_reply",
                    "variant_public_id" => fallback.public_id, "status" => "failed", "variant_status" => "failed",
                    "failure_reason_key" => "model_refused", "finish_quality" => "refused",
                    "refusal_category" => "cyber" }],
      items_since(mark).select { |item| item.item_type == "turn_status" }.map(&:payload)
  end

  # Nothing is re-sent that nobody declared, and a content-protection stop
  # is the provider's verdict on the content itself: no model gets it again.
  test "no declaration, a content block, or a fallback that cannot take the request stands at once" do
    declare!(fallback_model: nil)
    assert_stands(reply!) { refuse! }

    declare!(fallback_model: "dev/mock-unmetered")
    assert_stands(reply!, quality: "blocked", category: "SPII") { block! }

    # The declaration is read live at the switch and judged there against
    # the reply's own request, so a ref the catalog no longer resolves is a
    # stand, never a sample that fails for another reason.
    @agent.update_columns(fallback_model: "dev/retired-model")
    assert_stands(reply!) { refuse! }
  end

  # The declined sample sealed its model's resolved parameters, that
  # model's defaults included. The fallback re-asks under the caller's own
  # choices and its own defaults — never the declining model's — and a
  # choice the fallback cannot take is the stand.
  test "the fallback re-asks under the caller's parameters, never the declining model's defaults" do
    declare!(fallback_model: "dev/mock-text-only")
    turn = reply!(request_options: { "temperature" => 0.2 })
    refuse!
    converge!

    fallback = turn.reload.conversation_turn_variants.order(:position).last
    assert_equal ["fallback", "mock-text-only"], fallback.values_at(:source, :model_ref)
    assert_equal({ "temperature" => 0.2, "max_output_tokens" => 256, "top_p" => 1.0,
                   "output_format" => { "type" => "text" } },
      fallback.model_invocation.request_options.slice("temperature", "max_output_tokens", "top_p", "output_format"))
    apply_via(admitted_attempt, sse_success("answered"))
    converge!

    declare!(fallback_model: "dev/mock-unmetered")
    assert_stands(reply!(request_options: { "temperature" => 0.2 })) { refuse! }
  end

  # A person's regenerate on ANOTHER model is the same re-ask: the caller's
  # own parameters and the new model's defaults, never the old model's —
  # one reader of what a re-ask on another model carries.
  test "a person's regenerate on another model carries the caller's parameters, as the fallback does" do
    turn = reply!
    apply_via(admitted_attempt, sse_success("answered"))
    converge!

    regenerated = regenerate!(turn, provider_id: "dev", model_ref: "mock-unmetered")

    assert_equal ["mock-unmetered", nil], regenerated.values_at(:model_ref, :reasoning_effort),
      "the old model's effort is its own vocabulary"
    assert_equal({}, regenerated.model_invocation.request_options.except("instructions", "prompt_cache"),
      "none of the old model's defaults ride to a model whose vocabulary has none of them")
    assert_equal({ "kind" => "mainline", "tier" => "1h", "tail" => true },
      regenerated.model_invocation.request_options.fetch("prompt_cache"), "the request's kind is the conversation's")

    apply_via(admitted_attempt, sse_success("answered again"))
    converge!
    regenerated = regenerate!(turn.reload, provider_id: "dev", model_ref: "mock-text-only")
    assert_equal({ "temperature" => 1.0, "max_output_tokens" => 256 },
      regenerated.model_invocation.request_options.slice("temperature", "max_output_tokens"),
      "a model with defaults of its own asks under them")
  end

  # The bound is the turn's own history, whatever the origin chain: a
  # person's regenerate takes the ACTIVE sample as its origin, so a model
  # that declined an earlier regenerate is still never picked.
  test "a person's refused regenerate never switches to a model that already declined this turn" do
    turn = reply!
    refuse!
    converge!
    refuse!
    converge!
    original = turn.reload.active_variant
    assert_equal ["failed", "inference"], [turn.status, original.source], "the refused original stays the face"

    regenerated = regenerate!(turn)
    assert_equal [original.id, "mock-text"], regenerated.values_at(:origin_variant_id, :model_ref)
    refuse!
    converge!

    assert_equal ["failed", original.id], turn.reload.values_at(:status, :active_variant_id)
    assert_equal %w[inference fallback inference], turn.conversation_turn_variants.order(:position).pluck(:source),
      "the fallback declined this turn already, off the regenerate's origin chain: nothing re-asks it"
  end

  # The stop lands in the window between the refused call's apply and its
  # converge: the reply settles failed on the spot, no fallback is minted,
  # and the converger finds nothing left to decide.
  test "a stop in the window settles the refused reply with no fallback" do
    turn = reply!
    refuse!

    result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    ))

    assert_predicate result, :accepted?
    assert_equal ["failed", "failed"], [turn.reload.status, turn.active_variant.status]
    assert_nil @conversation.reload.active_turn_id
    assert_not_nil turn.active_variant.model_invocation.terminal_event_recorded_at
    converge!
    assert_equal 1, turn.conversation_turn_variants.count, "the stop wins over a fallback nobody asked for"
    assert_equal ["failed", "model_refused"],
      @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last
        .payload.values_at("status", "failure_reason_key")
  end

  # AN OVERLOADED REPLY takes the same one switch: the provider said it was overloaded on every
  # budgeted attempt, so the converger re-asks once on the answerer's fallback, the turn held running.
  test "a reply overloaded on every attempt re-asks once on the answerer's fallback" do
    turn = reply!
    overloaded = turn.active_variant

    overload!
    converge!

    assert_equal "failed", overloaded.reload.status
    assert_equal ["running", overloaded.id], turn.reload.values_at(:status, :active_variant_id)
    fallback = turn.conversation_turn_variants.order(:position).last
    assert_equal ["fallback", "mock-unmetered"], fallback.values_at(:source, :model_ref)
    assert_equal({ "from" => "dev/mock-text", "to" => "dev/mock-unmetered", "reason" => "provider_overloaded" },
      @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last
        .payload.fetch("model_change"))
  end

  test "a stop in the window settles the overloaded reply with no fallback" do
    turn = reply!
    overload!

    result = Conversations::Turns::Cancel.call(Conversations::Turns::Cancel::Command.new(
      conversation: @conversation, acting_user: @human
    ))

    assert_predicate result, :accepted?
    assert_equal ["failed", "failed"], [turn.reload.status, turn.active_variant.status]
    converge!
    assert_equal 1, turn.conversation_turn_variants.count, "the stop wins over a fallback nobody asked for"
    assert_equal ["failed", "provider_overloaded"],
      @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last
        .payload.values_at("status", "failure_reason_key")
  end

  private

    # Every budgeted attempt of the running reply answers the provider's overload.
    def overload!
      invocation = @conversation.model_invocations.order(:id).last
      3.times do
        ModelInvocation.where(id: invocation.id).update_all(next_admission_at: 1.second.ago)
        apply_via(admitted_attempt, json_response(529, { "error" => { "type" => "overloaded_error", "message" => "Overloaded" } }))
      end
      assert_equal "provider_overloaded", invocation.reload.failure_reason_key
    end

    def declare!(fallback_model:)
      outcome = Users::DeclareConfiguration.call(user: @agent, tool_definitions: [], approval_mode: nil,
        approval_rules: nil, prompt_mechanism: nil, prompt_template: nil, compaction_policy: nil,
        default_model: "dev/mock-text", fallback_model: fallback_model)
      assert_equal :declared, outcome.outcome, outcome.user.errors.full_messages.inspect
    end

    def accept!(text:, delivery_mode: "queue", kind: "message", **overrides)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(**{
        host: @conversation, acting_user: @human, kind: kind,
        role: "user", entries: [{ "text" => text }], visible_in_context: true,
        delivery_mode: delivery_mode, context_mode: nil, context_options: nil, expected_context_revision: nil,
        expected_tail_turn_public_id: nil, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil,
      }.merge(overrides)))
      assert_predicate result, :accepted?
      result.value
    end

    # A tool-less answerer's reply, running on the dev lane's text model.
    def reply!(**overrides)
      accept!(kind: "direct_reply", text: "the prompt", provider_id: "dev", model_ref: "mock-text", **overrides)
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.conversation_turns.order(:position).last
      assert_equal ["direct_reply", "running", "inference"], [turn.kind, turn.status, turn.active_variant.source]
      turn
    end

    def regenerate!(turn, **overrides)
      result = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(**{
        conversation: @conversation, turn_public_id: turn.public_id,
        acting_user: @human, provider_id: nil, model_ref: nil,
        reasoning_effort: nil, request_options: nil,
      }.merge(overrides)))
      assert_predicate result, :accepted?
      result.value
    end

    def admitted_attempt
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation.conversation_id == @conversation.id
      end
      raise "not admitted" if admitted.nil?

      clear_enqueued_jobs
      admitted.attempt
    end

    # The Anthropic shape: the lane whose refusal names its category.
    def refuse!
      refused = SimpleInference::Protocols::AnthropicMessages.new(
        base_url: "https://api.anthropic.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "id" => "msg_1", "content" => [], "stop_reason" => "refusal",
          "stop_details" => { "category" => "cyber", "explanation" => "The request asked for an exploit." },
          "usage" => { "input_tokens" => 2, "output_tokens" => 0 },
        }))
      ).create(model: "claude-opus-5-5", input: "Hello", max_output_tokens: 4096)
      apply_provider_result(admitted_attempt, refused, adapter_profile: "anthropic_messages")
    end

    # A Gemini content-protection stop: the lane that types BLOCKED.
    def block!
      blocked = SimpleInference::Protocols::GeminiGenerateContent.new(
        base_url: "https://generativelanguage.googleapis.com", api_key: "secret",
        adapter: InvocationHarness::FakeAdapter.new(json_response(200, {
          "candidates" => [{ "content" => { "parts" => [{ "text" => "partial" }] }, "finishReason" => "SPII" }],
          "usageMetadata" => { "promptTokenCount" => 3, "candidatesTokenCount" => 1, "totalTokenCount" => 4 },
        }))
      ).create(model: "gemini-3.8-flash", input: "Hello")
      apply_provider_result(admitted_attempt, blocked, adapter_profile: "gemini_generate_content")
    end

    def converge!
      Conversations::Turns::Converge.call
      clear_enqueued_jobs
    end

    def assert_stands(turn, quality: "refused", category: "cyber")
      yield
      converge!

      assert_equal 1, turn.conversation_turn_variants.count, "nothing asked again"
      assert_equal ["failed", "failed"], [turn.reload.status, turn.active_variant.status]
      assert_nil @conversation.reload.active_turn_id
      assert_equal ["failed", "model_refused", quality, category],
        @conversation.conversation_event_items.where(item_type: "turn_status").order(:sequence).last
          .payload.values_at("variant_status", "failure_reason_key", "finish_quality", "refusal_category")
    end

    def last_sequence = @conversation.conversation_event_items.maximum(:sequence).to_i

    def items_since(sequence)
      @conversation.conversation_event_items.where(sequence: (sequence + 1)..).order(:sequence).to_a
    end
end
