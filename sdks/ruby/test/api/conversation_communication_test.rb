require "test_helper"
require_relative "../support/conversation_fixtures"

class ApiConversationCommunicationTest < Minitest::Test
  include CybrosAgentTest::ConversationFixtures

  def test_shared_communication_cases_use_public_resources
    pack = CybrosAgentTest::ContractFixtures.pack("communication.json")
    pack.fetch("cases").each do |example|
      body = example.fetch("body")
      scope = chat([[example.fetch("status"), example.fetch("headers"), body]])
      if example.fetch("status") == 409
        error = assert_raises(CybrosAgent::Api::Conflict) { read_case(scope, pack, example) }
        assert_equal body.dig("error", "code"), error.code
        next
      end
      result = read_case(scope, pack, example)
      case example.fetch("operation")
      when "link_create"
        assert_equal body.dig("link", "public_id"), result.public_id
        assert_equal example.fetch("headers")["Idempotency-Replayed"] == "true", result.replayed?
        assert_equal({ "link" => pack.fetch("link_request") }, request.fetch(:body))
        assert_equal "communication-key", request.fetch(:headers).fetch("Idempotency-Key")
      when "link_read", "link_close"
        assert_equal body.fetch("link"), wire_link(result)
      when "link_list"
        assert_equal body.fetch("links"), result.items.map { |link| wire_link(link) }
        assert_equal body.fetch("next_after"), result.next_after
      when "inputs"
        expected = body.fetch("inputs").first
        actual = result.items.first
        %w[communication_kind link_public_id requested_delivery_mode on_target_end fallback_reason sender_conversation_public_id].each do |field|
          assert_equal [expected[field]], [actual.public_send(field)], example.fetch("name")
        end
        if expected["callback_result"]
          assert_equal expected.fetch("callback_result"), JSON.parse(JSON.generate(actual.callback_result.to_h))
        end
      when "turn"
        assert_equal body.dig("turn", "communication_kind"), result.communication_kind
        assert_equal body.dig("turn", "link_public_id"), result.link_public_id
        assert_equal body.dig("turn", "sender_run_public_id"), result.sender_run_public_id
        assert_equal body.dig("turn", "sender_task_key"), result.sender_task_key
      when "events"
        assert_equal body.fetch("events").first.fetch("payload"), result.items.first.payload
        assert_equal "input_deleted", result.items.first.type
      when "task"
        assert_equal [body.dig("task", "structured_content")], [result.structured_content], example.fetch("name")
        assert_equal body.dig("task", "status"), result.task.status
        assert_equal body.dig("task", "output"), result.output
      else
        flunk "unhandled communication case #{example.fetch("operation")}"
      end
    end
  end

  def test_links_reject_empty_keys_before_transport_and_encode_bound_identifiers
    scope = chat([])
    assert_raises(ArgumentError) do
      scope.links.create(agent_public_id: "a", peer_conversation_public_id: "b", peer_agent_public_id: "c", idempotency_key: "")
    end
    assert_empty @transport.requests
    pack = CybrosAgentTest::ContractFixtures.pack("communication.json")
    fixture = pack.fetch("cases").find { |entry| entry.fetch("name") == "link_closed" }.fetch("body")
    chat([[200, {}, fixture]]).links.close("link / id")
    assert_equal "#{PATH}/links/link%20%2F%20id/closure", request.fetch(:path)
    assert_equal :post, request.fetch(:method)
  end

  private

    def read_case(scope, pack, example)
      case example.fetch("operation")
      when "link_create"
        scope.links.create(**pack.fetch("link_request").transform_keys(&:to_sym), idempotency_key: "communication-key")
      when "link_read" then scope.links.fetch(pack.fetch("link_public_id"))
      when "link_close" then scope.links.close(pack.fetch("link_public_id"))
      when "link_list" then scope.links.list(state: "all", after: "previous", limit: 1)
      when "inputs" then scope.inputs.list
      when "turn" then scope.turns.fetch("turn")
      when "events" then scope.events
      when "task"
        CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
          .workspace(WORKSPACE_ID).run("original-run").task("original-task")
      else raise "unknown communication operation"
      end
    end

    def wire_link(link)
      JSON.parse(JSON.generate(link.to_h.merge(endpoint: link.endpoint.to_h, peer: link.peer.to_h)))
    end
end
