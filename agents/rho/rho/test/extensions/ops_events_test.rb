require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsEventsTest < Minitest::Test
  include RhoTest::OpsHarness

  class EventApi < NexusDoubles::FakeAgentApi
    def initialize(page: { "events" => [], "pagination" => { "next_after" => nil, "watermark" => 0 } }, status: 200, **options)
      super(**options)
      @page = page
      @event_status = status
    end

    def call(path, **options)
      return super unless path.end_with?("/events")

      requests << [path, options[:credential], options[:params]]
      CybrosAgent::Response.new(status: @event_status, headers: {}, body: @page)
    end
  end

  def test_events_resolves_a_conversation_and_its_backing_loop_to_the_same_feed
    page = { "events" => [{
      "public_id" => "ev-9", "sequence" => 9, "cursor" => "cursor-9", "type" => "input_materialized",
      "resource" => { "type" => "conversation", "public_id" => "c-1" }, "occurred_at" => "2026-09-20T00:00:00Z",
      "payload" => { "input_public_id" => "cin-1", "turn_public_id" => "t-1" },
    }], "pagination" => { "next_after" => "next/+==", "watermark" => 12 } }
    api = EventApi.new(page: page)
    daemon = member_ready(boot, api)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-1", loop: "al-1")

    %w[c-1 al-1].each do |id|
      response = request(daemon, :get, "/loops/events?public_id=#{id}&after=opaque%2F%2B%3D%3D&limit=3", token: bearer(daemon))

      assert_equal "200", response.code, response.body
      assert_includes response["content-type"], "application/json"
      assert_equal page, JSON.parse(response.body)
    end
    reads = api.requests.select { |path, _, _| path.end_with?("/events") }
    assert_equal 2, reads.length
    reads.each do |path, credential, params|
      assert_equal "/agent_api/v1/workspaces/ws-1/conversations/c-1/events", path
      assert_equal NexusDoubles::MEMBER_TOKEN, credential
      assert_equal({ "after" => "opaque/+==", "limit" => 3 }, params)
    end
  end

  def test_events_reads_a_standalone_hosts_feed_without_following_it
    api = EventApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/loops/events?public_id=al-9", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_includes response["content-type"], "application/json"
    assert_equal({ "events" => [], "pagination" => { "next_after" => nil, "watermark" => 0 } }, JSON.parse(response.body))
    reads = api.requests.select { |path, _, _| path.end_with?("/events") }
    assert_equal 1, reads.length
    assert_equal "/agent_api/v1/workspaces/ws-1/agent_loops/al-9/events", reads.first.first
    assert_nil reads.first.last
    assert_empty daemon.context.runs
  end

  def test_events_keeps_authentication_and_required_host_guards
    api = EventApi.new
    daemon = member_ready(boot, api)

    assert_equal "401", request(daemon, :get, "/loops/events?public_id=al-1").code
    response = request(daemon, :get, "/loops/events", token: bearer(daemon))
    assert_equal "400", response.code, response.body
    assert_equal "public_id is required", JSON.parse(response.body).dig("error", "message")
    assert_empty api.requests.select { |path, _, _| path.end_with?("/events") }
  end

  def test_events_relays_the_kernels_refusal_without_retrying
    api = EventApi.new(trace: NexusDoubles::RUNNING_TRACE, status: 429,
      page: { "error" => { "code" => "rate_limited", "message" => "Read later" } })
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/loops/events?public_id=al-9", token: bearer(daemon))

    assert_equal "429", response.code, response.body
    assert_equal "rate_limited", JSON.parse(response.body).dig("error", "code")
    assert_equal "rate limited; retry after 1s", JSON.parse(response.body).dig("error", "message")
    assert_equal 1, JSON.parse(response.body).dig("error", "retry_after")
    assert_equal 1, api.requests.count { |path, _, _| path.end_with?("/events") }
  end
end
