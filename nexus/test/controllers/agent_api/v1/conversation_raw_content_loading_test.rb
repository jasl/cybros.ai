require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationRawContentLoadingTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include InvocationHarness

  test "materializing a raw reply batches its fragments and preserves the submitted request" do
    _, one = materialize_raw_reply(1)
    _, many = materialize_raw_reply(21)

    assert_batched_reads(one, many, "raw input materialization")
  end

  test "settling a provider refusal batches its native reasoning check" do
    one = settle_refusal(1)
    many = settle_refusal(21)

    assert_batched_reads(one, many, "provider refusal settlement")
  end

  private

    def materialize_raw_reply(size)
      conversation = create_conversation!
      entries = Array.new(size) do |index|
        { "role" => index.even? ? "user" : "assistant",
          "parts" => [{ "type" => "text", "text" => "Message #{size}:#{index}" }] }
      end
      clear_enqueued_jobs
      post conversation_inputs_path(conversation), headers: auth(SecureRandom.uuid), as: :json,
        params: { input: { kind: "direct_reply", context_mode: "raw",
                           model: { model: "dev/mock-text" }, entries: entries } }
      assert_response :accepted

      Current.reset
      queries = fragment_reads { perform_enqueued_jobs(only: Conversations::Inputs::DrainJob) }
      turn = conversation.conversation_turns.sole
      variant = turn.active_variant
      assert_nil variant.agent_run
      get request_path(conversation, turn, variant), headers: auth
      assert_response :ok
      assert_equal entries, response.parsed_body.dig("request", "entries")
      [conversation, queries]
    end

    def settle_refusal(size)
      conversation, = materialize_raw_reply(size)
      invocation = conversation.model_invocations.sole
      attempt = ModelInvocations::AdmitQueuedWork.call.admitted.map(&:attempt)
        .find { |candidate| candidate.model_invocation_id == invocation.id }
      assert_not_nil attempt
      apply_via(attempt, json_response(400, { "error" => { "message" => "request refused" } }))
      assert_equal "provider_http_error", invocation.reload.failure_reason_key

      queries = fragment_reads do
        Conversations::Turns::ConvergeJob.perform_now(conversation.id, { "invocation_id" => invocation.id })
      end
      assert_equal "failed", conversation.conversation_turns.sole.status
      assert_nil conversation.reload.reasoning_replay_downgraded_at,
        "ordinary text never trips the native reasoning replay downgrade"
      queries
    end

    def assert_batched_reads(one, many, operation)
      assert_operator one.length, :>, 0
      assert_operator many.length, :<=, one.length, -> {
        "#{operation} must not add a fragment read per message.\n" \
          "One message:\n#{one.join("\n")}\nMany messages:\n#{many.join("\n")}"
      }
    end

    def fragment_reads
      queries = []
      observer = lambda do |*, payload|
        sql = payload.fetch(:sql)
        if !payload[:cached] && sql.match?(/\ASELECT\b.*\bFROM "content_fragments"/m)
          queries << sql
        end
      end
      ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      queries
    end
end
