require "test_helper"

class CoreHistoryProjectionTest < Minitest::Test
  include RhoTest::CliHarness

  def test_history_search_and_edits_use_shared_doors_with_the_saved_workspace
    seen = []
    history = { "turns" => [{ "public_id" => "turn-1", "content" => "Answer" }], "pagination" => { "has_older" => true } }
    search = { "matches" => [{ "conversation_public_id" => "chat-1", "excerpt" => "Answer" }], "pagination" => { "next_after" => "next" } }
    variant = { "public_id" => "variant-edit", "content" => "New answer" }
    turn = { "public_id" => "turn-1", "inherited" => true }
    announce(endpoint: recording_routed_endpoint(seen, {
      "GET /conversations/history" => [[200, history]], "GET /conversations/search" => [[200, search]],
      "POST /conversations/turns/edit" => [[200, { "variant" => variant }]],
      "POST /conversations/turns/delete" => [[200, { "deleted" => turn }]],
      "POST /conversations/turns/view" => [[200, { "turn" => turn }]],
    }))

    assert_equal history, core.history("chat-1", before_position: 7, limit: 10, workspace_public_id: "ws-original")
    assert_equal search, core.search_conversations(query: "Search words", after: "next page", archived: "include", workspace_public_id: "ws-original")
    assert_equal variant, core.edit_turn("chat-1", "turn-1", text: "New answer", workspace_public_id: "ws-original")
    assert_equal turn, core.delete_turn("chat-1", "turn-1", workspace_public_id: "ws-original")
    assert_equal turn, core.turn_view_state("chat-1", "turn-1", concealed: false, workspace_public_id: "ws-original")
    assert_equal turn, core.turn_view_state("chat-1", "turn-1", visibility: "excluded_from_context", workspace_public_id: "ws-original")

    gets = seen.grep(%r{\AGET /conversations/}).map { |request| URI.decode_www_form(URI.parse(request.lines.first.split[1]).query).to_h }
    assert_equal({ "public_id" => "chat-1", "before_position" => "7", "limit" => "10", "workspace_public_id" => "ws-original" }, gets.first)
    assert_equal "Search words", gets.last.fetch("query")
    bodies = seen.grep(/\APOST /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal ["ws-original"] * 4, bodies.map { |body| body.fetch("workspace_public_id") }
    assert_equal false, bodies[2].fetch("concealed")
    assert_equal "excluded_from_context", bodies[3].fetch("visibility")
  end

  def test_branch_and_execution_controls_carry_explicit_workspace_and_fork_key
    seen = []
    row = { "public_id" => "result" }
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations/rewind" => [[200, { "rewind" => row }]],
      "POST /conversations/regenerate" => [[200, { "regenerate" => row }]],
      "POST /runs/pause" => [[200, { "run" => row }]], "POST /runs/resume" => [[200, { "run" => row }]],
      "POST /runs/retry" => [[200, { "task" => row }]], "POST /runs/abandon" => [[200, { "task" => row }]],
      "POST /compact" => [[200, { "compacted" => row }]],
      "POST /conversations/prompt_preview" => [[200, { "preview" => row }]],
      "GET /conversations/variants" => [[200, { "variants" => [row] }]],
      "GET /runs/transcript" => [[200, { "transcript" => row }]],
    }))
    core.rewind("chat", "turn", keep_checkpoints: true, idempotency_key: "saved-key", workspace_public_id: "ws-original")
    core.regenerate("chat", "turn", idempotency_key: "regenerate-test", keep_checkpoints: true, workspace_public_id: "ws-original")
    core.pause("run_public_id", workspace_public_id: "ws-original")
    core.resume("run_public_id", workspace_public_id: "ws-original")
    core.retry("run_public_id", workspace_public_id: "ws-original")
    core.abandon("run_public_id", workspace_public_id: "ws-original")
    core.compact("chat", workspace_public_id: "ws-original")
    core.prompt_preview("chat", workspace_public_id: "ws-original")
    core.variants("chat", "turn", workspace_public_id: "ws-original")
    core.transcript("run_public_id", workspace_public_id: "ws-original")

    bodies = seen.grep(/\APOST /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal ["ws-original"] * 8, bodies.map { |body| body.fetch("workspace_public_id") }
    assert_equal "saved-key", bodies.first.fetch("idempotency_key")
    assert_equal [true, true], bodies.first(2).map { |body| body.fetch("keep_checkpoints") }
    seen.grep(%r{\AGET /(?:conversations|runs)/}).each { |request| assert_includes request.lines.first, "workspace_public_id=ws-original" }
  end

  def test_kernel_branch_and_apex_refusals_remain_typed
    announce(endpoint: routed_endpoint({
      "POST /conversations/turns/edit" => [[409, { "error" => { "code" => "branch_required", "message" => "Fork this history first" } }]],
      "POST /conversations/turns/delete" => [[409, { "error" => { "code" => "apex_only", "message" => "Only the tail can be deleted" } }]],
    }))
    error = assert_raises(Rho::Core::Refused) { core.edit_turn("chat", "middle", text: "Change") }
    assert_equal [409, "branch_required"], [error.status, error.code]
    error = assert_raises(Rho::Core::Refused) { core.delete_turn("chat", "middle") }
    assert_equal [409, "apex_only"], [error.status, error.code]
  end
end
