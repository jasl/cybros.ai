require "test_helper"
require "test_helpers/agent_run_api_test_helper"

class AgentAPI::V1::AgentRunModelReadsTest < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper
  include RunLaneTestHelper

  setup do
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    declare_tools!(@agent)
  end

  test "the loop list batches current selections across distinct conversations" do
    first = add_reply_loop
    get loops_path, headers: auth
    assert_response :ok
    one = list_queries
    assert_equal [first.public_id], response.parsed_body.fetch("runs").pluck("public_id")
    others = Array.new(2) { add_reply_loop }
    three = list_queries

    assert_equal one.length, three.length, -> {
      "more loop-backed rows must not add selection or association queries\n" \
        "One loop:\n#{one.join("\n")}\nThree loops:\n#{three.join("\n")}"
    }
    rows = response.parsed_body.fetch("runs").index_by { |row| row.fetch("public_id") }
    [first, *others].each do |agent_run|
      assert_equal "dev/mock-text", rows.fetch(agent_run.public_id).dig("turn", "model", "model")
    end
  end

  private

    def add_reply_loop
      conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      _turn, agent_run = materialize_loop_reply!(conversation, agent: @agent)
      agent_run
    end

    def list_queries
      # The request executor may enable caching inside GET. Start both samples
      # empty so the warm-up and intervening writes cannot bias their counts.
      ApplicationRecord.connection_pool.clear_query_cache
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) {
        queries << payload[:sql] unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      }
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get loops_path, headers: auth
      end
      assert_response :ok
      queries
    end
end
