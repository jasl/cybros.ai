require "test_helper"

class CoreWorkspaceScopeTest < Minitest::Test
  include RhoTest::CliHarness

  def test_a_channels_original_workspace_reaches_every_host_read_after_local_following_ends
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /conversations/detail" => [[200, { "conversation" => { "public_id" => "restored" } }]],
      "GET /conversations/turns" => [[200, { "turns" => [] }]],
      "GET /inputs" => [[200, { "inputs" => [] }]],
      "GET /runs/events" => [[200, { "events" => [], "pagination" => { "next_after" => nil, "watermark" => 0 } }]]))

    assert_equal "restored", core.conversation("restored", workspace_public_id: "original").fetch("public_id")
    assert_empty core.turns("restored", workspace_public_id: "original").fetch("turns")
    assert_empty core.inputs("restored", workspace_public_id: "original")
    assert_empty core.host_events("restored", workspace_public_id: "original").items

    reads = seen.grep(%r{\AGET /(conversations|inputs|runs/events)})
    assert_equal 4, reads.length
    reads.each do |request|
      query = URI.decode_www_form(URI.parse(request.lines.first.split[1]).query).to_h
      assert_equal({ "public_id" => "restored", "workspace_public_id" => "original" }, query)
    end
  end

  def test_restore_attach_say_and_stop_keep_the_explicit_workspace_without_changing_omission
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /followers/attach" => [[200, { "conversation" => { "public_id" => "restored" } }]],
      "POST /say" => [[200, { "input" => { "public_id" => "input-1" } }]],
      "POST /stop" => [[200, { "stopped" => { "public_id" => "restored" } }]]))

    assert_equal "restored", core.attach("restored", host_type: "conversation", workspace_public_id: "original").dig("conversation", "public_id")
    assert_equal "input-1", core.say("restored", "again", workspace_public_id: "original").dig("input", "public_id")
    assert_equal "restored", core.stop("restored", workspace_public_id: "original").fetch("public_id")
    posts = seen.grep(/\APOST /)
    assert_equal ["original"] * 3, posts.map { |request| JSON.parse(request.partition("\r\n\r\n").last).fetch("workspace_public_id") }

    core.attach("restored", host_type: "conversation")
    core.say("restored", "again")
    core.stop("restored")
    assert seen.grep(/\APOST /).last(3).none? { |request| JSON.parse(request.partition("\r\n\r\n").last).key?("workspace_public_id") }
  end

  def test_queue_writes_keep_the_channels_conversation_and_original_workspace
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "POST /inputs/delete" => [[200, { "deleted" => { "public_id" => "input-1" } }]],
      "POST /inputs/update" => [[200, { "input" => { "public_id" => "input-2" } }]]))

    scope = { host_type: "conversation", workspace_public_id: "original" }
    core.delete_input("restored", "input-1", **scope)
    core.update_input("restored", "input-2", text: "Corrected request", **scope)

    bodies = seen.grep(/\APOST /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal %w[input-1 input-2], bodies.map { |body| body.fetch("input_public_id") }
    assert bodies.all? { |body| body.slice("public_id", "host_type", "workspace_public_id") ==
      { "public_id" => "restored", "host_type" => "conversation", "workspace_public_id" => "original" } }
    assert_equal "Corrected request", bodies.last.fetch("text")
  end
end
