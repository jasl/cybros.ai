require "test_helper"
require_relative "../support/ops_harness"

class OpsHistoryProjectionTest < Minitest::Test
  include RhoTest::OpsHarness

  class HistoryApi < NexusDoubles::FakeAgentApi
    attr_reader :history_writes, :fork_keys

    def initialize
      super(turns: [{ "public_id" => "t0", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-01T00:00:00Z",
        "answering_user_public_id" => "agent-1" }])
      @history_writes, @fork_keys = [], []
    end

    def call(path, **fields)
      @fork_keys << fields.fetch(:headers).fetch("Idempotency-Key") if path.end_with?("/forks")
      super
    end

    def conversation_response(method, path, credential, body, params: nil)
      return super unless credential == NexusDoubles::MEMBER_TOKEN

      if method == :get && path.end_with?("/conversation_search")
        return respond(200, { "matches" => [{ "conversation_public_id" => "chat", "title" => "Research", "field" => "content",
          "inherited" => false, "truncated" => false, "excerpt" => "A searchable answer" }], "pagination" => { "next_after" => "search-next" } })
      end
      if method == :get && path.end_with?("/history")
        return respond(200, { "conversation" => { "public_id" => "chat", "title" => "Research" }, "turns" => [{
          "public_id" => "turn", "position" => 1, "kind" => "direct_reply", "role" => "assistant", "created_at" => "2026-10-01T00:00:00Z",
          "prompt" => "Question", "content" => "Answer", "truncated" => false,
        }], "pagination" => { "before_position" => 1, "after_position" => 1, "has_older" => true, "has_newer" => false }, "truncated" => false })
      end
      if path.end_with?("/turns/turn/edit")
        @history_writes << [method, path, body]
        return respond(200, { "variant" => { "public_id" => "edited", "source" => "edit", "status" => "completed", "active" => true,
          "content" => body.fetch("edit").fetch("text") } })
      end
      if path.end_with?("/turns/turn")
        @history_writes << [method, path, body]
        return method == :delete ? respond(204, nil) : respond(200, { "turn" => { "public_id" => "turn", "inherited" => true } })
      end
      super
    end
  end

  def test_search_history_and_writes_flow_through_the_member_sdk_without_following_a_host
    api = HistoryApi.new
    daemon = member_ready(boot, api)
    search = request(daemon, :get, "/conversations/search?query=words&after=previous&archived=include&limit=5", token: bearer(daemon))
    assert_equal "200", search.code, search.body
    assert_equal "search-next", JSON.parse(search.body).dig("pagination", "next_after")
    history = request(daemon, :get, "/conversations/history?public_id=chat&before_position=10&limit=5", token: bearer(daemon))
    assert_equal "200", history.code, history.body
    assert_equal "Answer", JSON.parse(history.body).dig("turns", 0, "content")
    assert_equal true, JSON.parse(history.body).dig("pagination", "has_older")
    assert api.requests.any? { |path, _, params| path.end_with?("/conversation_search") && params.fetch("query") == "words" && params.fetch("after") == "previous" }

    response = request(daemon, :post, "/conversations/turns/edit", token: bearer(daemon), body: { public_id: "chat", turn: "turn", text: "Corrected" })
    assert_equal "200", response.code, response.body
    assert_equal "Corrected", JSON.parse(response.body).dig("variant", "content")
    response = request(daemon, :post, "/conversations/turns/view", token: bearer(daemon), body: { public_id: "chat", turn: "turn", concealed: false })
    assert_equal "200", response.code, response.body
    assert_equal true, JSON.parse(response.body).dig("turn", "inherited")
    response = request(daemon, :post, "/conversations/turns/delete", token: bearer(daemon), body: { public_id: "chat", turn: "turn" })
    assert_equal "200", response.code, response.body
    assert_equal [[:post, { "edit" => { "text" => "Corrected" } }], [:patch, { "turn" => { "concealed" => false } }], [:delete, nil]],
      api.history_writes.map { |method, _path, body| [method, body] }
    assert_empty daemon.lineage.runs
  end

  def test_a_callers_fork_key_reaches_both_replays_and_keep_world_never_starts_a_restore
    api = HistoryApi.new
    daemon = member_ready(boot, api)
    2.times do
      response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
        body: { public_id: "chat", turn: "t0", keep_world: true, idempotency_key: "persisted-fork" })
      assert_equal "200", response.code, response.body
    end
    assert_equal ["persisted-fork", "persisted-fork"], api.fork_keys
    assert_empty api.loop_creates
  end

  def test_turn_projection_keeps_original_answerer_and_distinguishes_default_memory_from_explicit_off
    turns = [nil, { "bindings" => [] }].map.with_index do |memory_context, position|
      { "public_id" => "t#{position}", "position" => position, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-01T00:00:00Z",
        "answering_user_public_id" => "original-answerer", "active_variant" => {
          "public_id" => "v#{position}", "source" => "agent_loop", "status" => "completed", "content" => "Answer",
          "agent_loop_public_id" => "loop-#{position}", "memory_context" => memory_context } }
    end
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: turns))
    response = request(daemon, :get, "/conversations/turns?public_id=chat", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    rows = JSON.parse(response.body).fetch("turns")
    assert_equal ["original-answerer", "original-answerer"], rows.map { |row| row.fetch("answering_user_public_id") }
    assert_nil rows.first.fetch("active_variant").fetch("memory_context")
    assert_equal({ "bindings" => [] }, rows.last.fetch("active_variant").fetch("memory_context"))
  end

  def test_malformed_history_controls_do_not_call_the_kernel
    api = HistoryApi.new
    daemon = member_ready(boot, api)
    [[:get, "/conversations/history", nil],
      [:post, "/conversations/turns/edit", { public_id: "chat", turn: "turn" }],
      [:post, "/conversations/turns/view", { public_id: "chat", turn: "turn" }],
      [:post, "/conversations/turns/delete", { public_id: "chat" }]].each do |method, path, body|
      response = request(daemon, method, path, token: bearer(daemon), body: body)
      assert_equal "400", response.code, response.body
    end
    assert_empty api.history_writes
  end

  def test_turn_projection_keeps_each_worker_result_apart_from_the_parent_summary
    sources = %w[a b].map do |suffix|
      { "input_public_id" => "receipt-#{suffix}", "origin" => "child", "sender_conversation_public_id" => "child-#{suffix}",
        "sender_agent_loop_public_id" => "source-#{suffix}", "sender_task_key" => "r1t0", "result" => {
          "conversation_public_id" => "child-#{suffix}", "input_public_id" => "worker-input-#{suffix}",
          "turn_public_id" => "worker-turn-#{suffix}", "variant_public_id" => "worker-variant-#{suffix}",
          "requester_actor_public_id" => "requester-actor" } }
    end
    row = { "public_id" => "summary", "position" => 3, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-02T00:00:00Z",
      "answering_user_public_id" => "answerer", "input_public_id" => "receipt-b", "callback_sources" => sources,
      "active_variant" => { "public_id" => "summary-variant", "source" => "agent_loop", "status" => "completed",
        "content" => "Combined report", "agent_loop_public_id" => "summary-loop" } }
    input = NexusDoubles.input_row("receipt-a", "pending", text: "Worker result").merge("callback_result" => sources.first.fetch("result"))
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: [row], input_list: [input]))
    queued = request(daemon, :get, "/inputs?public_id=chat&host_type=conversation", token: bearer(daemon))
    assert_equal "200", queued.code, queued.body
    assert_equal sources.first.fetch("result"), JSON.parse(queued.body).fetch("inputs").first.fetch("callback_result")
    response = request(daemon, :get, "/conversations/turns?public_id=chat", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    turn = JSON.parse(response.body).fetch("turns").first
    assert_equal "receipt-b", turn.fetch("input_public_id")
    assert_equal sources, turn.fetch("callback_sources")
    assert_equal "Combined report", turn.fetch("active_variant").fetch("content")
    refute turn.key?("sender_agent_loop_public_id")
    refute turn.key?("sender_conversation_public_id")
    refute turn.key?("sender_task_key")
  end
end
