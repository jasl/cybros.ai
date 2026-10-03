require "test_helper"
require_relative "../support/ops_harness"

class OpsConversationsTest < Minitest::Test
  include RhoTest::OpsHarness

  class CatalogApi < NexusDoubles::FakeAgentApi
    attr_accessor :refusal
    attr_reader :writes

    def initialize
      super
      @writes = []
      @row = conversation_row("c-1").merge(
        "title" => "A durable conversation", "metadata" => { "label" => "work" }, "latest_event_cursor" => "cursor-9",
        "parent" => { "public_id" => "parent-1", "label" => "Research" },
        "context" => { "used_tokens" => 42, "as_of_model" => { "provider_id" => "dev", "model_ref" => "mock-text" } },
        "runner" => { "executor_public_id" => "runner-1", "presence" => "online", "display_name" => "Home server" },
        "access" => { "default" => "read", "entries" => [NexusDoubles.speaker_row("human-1").merge("level" => "full")] }
      )
    end

    def conversation_response(method, path, credential, body, params: nil)
      return super unless credential == NexusDoubles::MEMBER_TOKEN
      return @refusal if @refusal

      if method == :get && path.match?(%r{/conversations(?:/archived)?\z})
        archived = path.end_with?("/archived")
        rows = archived == !@row["archived_at"].nil? ? [@row] : []
        return respond(200, { "conversations" => rows, "pagination" => { "next_after" => "page-2" } })
      end
      if path.match?(%r{/conversations/c-1(?:/archive|/unarchive)?\z})
        case method
        when :patch
          @writes << body
          @row.merge!(body.fetch("conversation"))
        when :post
          @row["archived_at"] = path.end_with?("/unarchive") ? nil : "2026-09-29T00:00:00Z"
        else
          # The singular read returns the same durable row.
        end
        return respond(200, { "conversation" => @row })
      end

      super
    end
  end

  def test_conversation_routes_require_bearer_and_the_connected_member_plane
    daemon = boot
    [["get", "/conversations"], ["get", "/conversations/detail?public_id=c-1"],
     ["get", "/inputs?public_id=c-1&host_type=conversation"],
     ["patch", "/conversations"], ["post", "/conversations/archive"], ["post", "/conversations/unarchive"]].each do |verb, path|
      assert_equal "401", request(daemon, verb.to_sym, path).code
      response = request(daemon, verb.to_sym, path, token: bearer(daemon), body: { "public_id" => "c-1", "title" => "Title" })
      assert_equal "409", response.code
      assert_equal "member_plane_unavailable", JSON.parse(response.body).dig("error", "code")
    end
  end

  def test_listing_and_detail_use_the_adopted_workspace_without_attaching_a_host
    api = CatalogApi.new
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/conversations?after=older&limit=7", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    document = JSON.parse(response.body)
    assert_equal ["c-1"], document.fetch("conversations").map { |row| row.fetch("public_id") }
    assert_equal "Research", document.dig("conversations", 0, "parent", "label")
    assert_equal({ "next_after" => "page-2" }, document.fetch("pagination"))
    path, credential, params = api.requests.find { |entry| entry.first.end_with?("/conversations") }
    assert_equal "/agent_api/v1/workspaces/ws-1/conversations", path
    assert_equal NexusDoubles::MEMBER_TOKEN, credential
    assert_equal({ "after" => "older", "limit" => 7 }, params)

    response = request(daemon, :get, "/conversations/detail?public_id=c-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    row = JSON.parse(response.body).fetch("conversation")
    assert_equal "A durable conversation", row.fetch("title")
    assert_equal({ "limit" => 16, "held" => 0 }, row.fetch("input_queue"))
    assert_equal "dev", row.dig("context", "as_of_model", "provider_id")
    assert_equal "runner-1", row.dig("runner", "executor_public_id")
    assert_equal "full", row.dig("access", "entries", 0, "level")
    assert_equal "work", row.dig("metadata", "label")
    assert_equal "cursor-9", row.fetch("latest_event_cursor")
    assert_empty daemon.lineage.runs
  end

  def test_conversation_inputs_do_not_need_a_remembered_host
    api = NexusDoubles::FakeAgentApi.new(input_list: [NexusDoubles.input_row("cin-1", "pending", text: "Next question")])
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/inputs?public_id=c-1&host_type=conversation", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    queue = JSON.parse(response.body)
    assert_equal "c-1", queue.fetch("host_public_id")
    assert_equal [%w[cin-1 pending]], queue.fetch("inputs").map { |row| row.values_at("public_id", "state") }
    assert_equal({ "limit" => 16, "held" => 1 }, queue.fetch("input_queue"))
    assert_equal [["/agent_api/v1/workspaces/ws-1/conversations/c-1/inputs", NexusDoubles::MEMBER_TOKEN, nil]], api.requests
    assert_empty store.rows
    assert_empty daemon.lineage.runs
  end

  def test_archived_conversation_inputs_remain_readable_after_the_host_is_forgotten
    api = CatalogApi.new
    daemon = member_ready(boot, api)
    host = Rho::Host::Conversation.new(public_id: "c-1")
    store.remember(host, workspace: "ws-1")
    response = request(daemon, :post, "/conversations/archive", token: bearer(daemon), body: { public_id: "c-1" })
    assert_equal "200", response.code, response.body
    refute_nil JSON.parse(response.body).dig("conversation", "archived_at")
    # The archived event removes the follower's routing hint through this same cleanup.
    daemon.loops.forget(host)
    assert_empty store.rows
    api.requests.clear

    response = request(daemon, :get, "/inputs?public_id=c-1&host_type=conversation", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal({ "host_public_id" => "c-1", "inputs" => [], "input_queue" => { "limit" => 16, "held" => 0 } },
      JSON.parse(response.body))
    assert_equal [["/agent_api/v1/workspaces/ws-1/conversations/c-1/inputs", NexusDoubles::MEMBER_TOKEN, nil]], api.requests
    assert_empty store.rows, "reading the queue does not reattach an archived host"
  end

  def test_title_archive_and_restore_follow_the_existing_sdk_doors
    api = CatalogApi.new
    daemon = member_ready(boot, api)
    response = request(daemon, :patch, "/conversations", token: bearer(daemon), body: { "public_id" => "c-1", "title" => "Renamed" })
    assert_equal "200", response.code, response.body
    assert_equal "Renamed", JSON.parse(response.body).dig("conversation", "title")
    assert_equal [{ "conversation" => { "title" => "Renamed" } }], api.writes

    response = request(daemon, :post, "/conversations/archive", token: bearer(daemon), body: { "public_id" => "c-1" })
    assert_equal "200", response.code, response.body
    refute_nil JSON.parse(response.body).dig("conversation", "archived_at")
    assert_empty JSON.parse(request(daemon, :get, "/conversations", token: bearer(daemon)).body).fetch("conversations")
    archived = request(daemon, :get, "/conversations?archived=1&limit=3", token: bearer(daemon))
    assert_equal ["c-1"], JSON.parse(archived.body).fetch("conversations").map { |row| row.fetch("public_id") }
    assert api.requests.any? { |path, _, params| path.end_with?("/conversations/archived") && params == { "limit" => 3 } }

    response = request(daemon, :post, "/conversations/unarchive", token: bearer(daemon), body: { "public_id" => "c-1" })
    assert_equal "200", response.code, response.body
    assert_nil JSON.parse(response.body).dig("conversation", "archived_at")
    assert_equal ["c-1"], JSON.parse(request(daemon, :get, "/conversations", token: bearer(daemon)).body).fetch("conversations").map { |row| row.fetch("public_id") }
  end

  def test_malformed_control_inputs_and_kernel_refusals_remain_distinct
    api = CatalogApi.new
    daemon = member_ready(boot, api)
    ["/conversations?limit=0", "/conversations?limit=no", "/conversations/detail",
     "/inputs?host_type=conversation", "/inputs?public_id=c-1&host_type=thread"].each do |path|
      assert_equal "400", request(daemon, :get, path, token: bearer(daemon)).code
    end
    [["patch", "/conversations", { "public_id" => "c-1" }],
     ["post", "/conversations/archive", {}], ["post", "/conversations/unarchive", {}]].each do |verb, path, body|
      assert_equal "400", request(daemon, verb.to_sym, path, token: bearer(daemon), body: body).code
    end

    api.refusal = CybrosAgent::Response.new(status: 403, headers: {},
      body: { "error" => { "code" => "not_authorized", "message" => "Read access cannot rename" } })
    response = request(daemon, :patch, "/conversations", token: bearer(daemon), body: { "public_id" => "c-1", "title" => "Denied" })
    assert_equal "403", response.code, response.body
    assert_equal "not_authorized", JSON.parse(response.body).dig("error", "code")
    assert_empty api.writes

    api.refusal = CybrosAgent::Response.new(status: 404, headers: {},
      body: { "error" => { "code" => "not_found", "message" => "Conversation not found" } })
    api.requests.clear
    response = request(daemon, :get, "/inputs?public_id=c-1&host_type=conversation", token: bearer(daemon))
    assert_equal "404", response.code, response.body
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
    assert_equal [["/agent_api/v1/workspaces/ws-1/conversations/c-1/inputs", NexusDoubles::MEMBER_TOKEN, nil]], api.requests,
      "a refused conversation read is not retried or probed as a loop"
  end
end
