require "test_helper"
require "test_helpers/conversation_api_test_helper"

class AgentAPI::V1::ConversationReplySeedLoadingTest < ActionDispatch::IntegrationTest
  include ConversationAPITestHelper
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    declare_tools!(@agent)
  end

  test "scheduling a reply batches its seed fragments without changing the sealed request" do
    one = schedule_seed(1)
    many = schedule_seed(21)

    assert_operator one.length, :>, 0
    assert_operator many.length, :<=, one.length, -> {
      "More messages must not add per-fragment reads while scheduling the accepted reply.\n" \
        "One message:\n#{one.join("\n")}\nMany messages:\n#{many.join("\n")}"
    }
  end

  private

    def schedule_seed(size)
      conversation = Conversation.create!(workspace: @workspace,
        creating_user: @human, answering_user: @agent)
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
      perform_enqueued_jobs(only: Conversations::Inputs::DrainJob)
      turn = conversation.conversation_turns.sole
      variant = turn.active_variant
      agent_run = variant.agent_run
      assert_not_nil agent_run

      # The request accepted asynchronous work. Measure its scheduler after the
      # input writer has finished, so writes cannot hide per-entry seed reads.
      queries = fragment_queries do
        AgentRuns::ScheduleJob.perform_now(agent_run.id)
      end
      assert_empty queries.grep(/\AINSERT/),
        "scheduling an already sealed seed must not send its payloads through INSERT again"
      assert_equal 1, queries.grep(/FOR KEY SHARE\z/).length,
        "the immutable seed fragments need one locked identity lookup without a second fetch"
      get request_path(conversation, turn, variant), headers: auth
      assert_response :ok
      assert_equal entries, response.parsed_body.dig("request", "entries")
      queries
    end

    def fragment_queries
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        sql = payload.fetch(:sql)
        if !payload[:cached] && sql.match?(/\A(?:SELECT\b.*\bFROM|INSERT INTO) "content_fragments"/m)
          queries << sql
        end
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        ApplicationRecord.uncached { yield }
      end
      queries
    end
end
