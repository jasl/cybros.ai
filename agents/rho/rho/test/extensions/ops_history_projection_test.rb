require "test_helper"
require_relative "../support/ops_harness"

class OpsHistoryProjectionTest < Minitest::Test
  include RhoTest::OpsHarness

  class HistoryApi < NexusDoubles::FakeAgentApi
    attr_reader :history_writes, :fork_keys

    def initialize(history_fields: {})
      super(turns: [{ "public_id" => "t0", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-01T00:00:00Z",
        "answering_user_public_id" => "agent-1" }])
      @history_writes, @fork_keys = [], []
      @history_fields = history_fields
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
          "status" => "completed", "prompt" => "Question", "content" => "Answer", "truncated" => false,
        }], "pagination" => { "before_position" => 1, "after_position" => 1, "has_older" => true, "has_newer" => false }, "truncated" => false }.merge(@history_fields))
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
    assert_equal "completed", JSON.parse(history.body).dig("turns", 0, "status")
    refute JSON.parse(history.body).key?("execution")
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
    assert_empty daemon.lineage.followers
  end

  def test_history_forwards_the_selected_execution_window_and_preserves_its_projection
    execution = {
      "turn_public_id" => "turn", "variant_public_id" => "running-variant", "active" => false,
      "status" => "running", "run_public_id" => "running-run", "run_status" => "running",
      "rounds" => [{ "task_key" => "r1", "mainline" => true, "status" => "completed", "visibility" => "visible",
        "text_preview" => "Checking the result", "calls" => { "count" => 2, "items" => [
          { "task_key" => "r1t1", "name" => "read", "status" => "completed", "output_preview" => "Found the answer", "is_error" => false },
          { "task_key" => "r1t2", "name" => "bash", "status" => "running" },
        ] }, "branches" => ["r1t2"] }],
      "pagination" => { "next_before" => "older-rounds", "has_older" => true }, "truncated" => true,
    }
    api = HistoryApi.new(history_fields: { "execution" => execution })
    daemon = member_ready(boot, api)
    query = { "public_id" => "chat", "around_turn_public_id" => "turn", "include_execution" => "true",
      "execution_before" => "opaque/cursor+value", "execution_prefix" => "r1t2", "limit" => "5" }

    response = request(daemon, :get, "/conversations/history?#{URI.encode_www_form(query)}", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_equal query.reject { |key, _| key == "public_id" }, api.requests.find { |path, _, _| path.end_with?("/history") }.last
    assert_equal execution, JSON.parse(response.body).fetch("execution")
    assert_equal "Answer", JSON.parse(response.body).dig("turns", 0, "content")
    assert_empty daemon.lineage.followers
  end

  def test_history_preserves_an_explicitly_absent_execution
    api = HistoryApi.new(history_fields: { "execution" => nil })
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/conversations/history?public_id=chat&include_execution=true", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    assert_nil JSON.parse(response.body).fetch("execution")
  end

  def test_history_forwards_an_explicit_false_without_adding_execution
    api = HistoryApi.new
    daemon = member_ready(boot, api)

    response = request(daemon, :get, "/conversations/history?public_id=chat&include_execution=false", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    refute JSON.parse(response.body).key?("execution")
    assert_equal({ "include_execution" => "false" }, api.requests.find { |path, _, _| path.end_with?("/history") }.last)
  end

  def test_a_callers_fork_key_reaches_both_replays_and_keep_checkpoints_never_starts_a_restore
    api = HistoryApi.new
    daemon = member_ready(boot, api)
    2.times do
      response = request(daemon, :post, "/conversations/rewind", token: bearer(daemon),
        body: { public_id: "chat", turn: "t0", keep_checkpoints: true, idempotency_key: "persisted-fork" })
      assert_equal "200", response.code, response.body
    end
    assert_equal ["persisted-fork", "persisted-fork"], api.fork_keys
    assert_empty api.run_creates
  end

  def test_turn_projection_keeps_original_answerer_and_distinguishes_default_memory_from_explicit_off
    turns = [nil, { "bindings" => [] }].map.with_index do |memory_context, position|
      { "public_id" => "t#{position}", "position" => position, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-01T00:00:00Z",
        "answering_user_public_id" => "original-answerer", "active_variant" => {
          "public_id" => "v#{position}", "source" => "run", "status" => "completed", "content" => "Answer",
          "run_public_id" => "run-#{position}", "memory_context" => memory_context } }
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

  def test_turn_projection_preserves_the_reference_snapshot_marker
    contract = JSON.parse(File.read(File.expand_path("../../../../../contracts/nexus/v1/conversations.json", __dir__)))
    reference = contract.fetch("valid_reference_turn_fixture")
    daemon = member_ready(boot, NexusDoubles::FakeAgentApi.new(turns: [reference]))

    response = request(daemon, :get, "/conversations/turns?public_id=chat", token: bearer(daemon))

    assert_equal "200", response.code, response.body
    turn = JSON.parse(response.body).fetch("turns").first
    assert_equal true, turn.fetch("reference")
    assert_equal false, turn.fetch("inherited")
    refute turn.fetch("active_variant").key?("run_public_id")
  end

  def test_turn_projection_keeps_each_worker_result_apart_from_the_parent_summary
    sources = %w[a b].map do |suffix|
      { "input_public_id" => "receipt-#{suffix}", "origin" => "child", "sender_conversation_public_id" => "child-#{suffix}",
        "sender_run_public_id" => "source-#{suffix}", "sender_task_key" => "r1t0", "result" => {
          "conversation_public_id" => "child-#{suffix}", "input_public_id" => "worker-input-#{suffix}",
          "turn_public_id" => "worker-turn-#{suffix}", "variant_public_id" => "worker-variant-#{suffix}",
          "requester_speaker_public_id" => "requester-actor" } }
    end
    row = { "public_id" => "summary", "position" => 3, "kind" => "direct_reply", "role" => "assistant",
      "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-02T00:00:00Z",
      "answering_user_public_id" => "answerer", "input_public_id" => "receipt-b", "callback_sources" => sources,
      "active_variant" => { "public_id" => "summary-variant", "source" => "run", "status" => "completed",
        "content" => "Combined report", "run_public_id" => "summary-run" } }
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
    refute turn.key?("sender_run_public_id")
    refute turn.key?("sender_conversation_public_id")
    refute turn.key?("sender_task_key")
  end
end
