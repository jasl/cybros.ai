require "test_helper"

class CoreConversationsTest < Minitest::Test
  include RhoTest::CliHarness

  def test_prepared_upload_ids_and_their_retry_key_cross_the_same_conversation_doors
    seen = []
    announce(endpoint: recording_routed_endpoint(seen, {
      "POST /conversations" => [[201, { "conversation" => { "public_id" => "c-1" } }]],
      "POST /say" => [[200, { "input" => { "public_id" => "in-1" } }]],
    }))
    ids = %w[upload-one upload-two]
    core.open_conversation(upload_public_ids: ids, idempotency_key: "open-media", workspace_public_id: "ws-original")
    2.times do
      core.say("c-1", "", mode: "queue", upload_public_ids: ids,
        idempotency_key: "media-input", workspace_public_id: "ws-original", wait: false)
    end
    bodies = seen.grep(/\APOST /).map { |request| JSON.parse(request.partition("\r\n\r\n").last) }
    assert_equal [ids, ids, ids], bodies.map { |body| body.fetch("upload_public_ids") }
    assert_equal %w[open-media media-input media-input], bodies.map { |body| body.fetch("idempotency_key") }
    assert_equal ["ws-original"] * 3, bodies.map { |body| body.fetch("workspace_public_id") }
    assert_equal ["", ""], bodies.drop(1).map { |body| body.fetch("text") }
    error = assert_raises(Rho::Error) { core.say("c-1", "look", upload_public_ids: ids) }
    assert_includes error.message, "attachments_not_steerable"
    error = assert_raises(Rho::Error) do
      core.open_conversation(attachments: [__FILE__], upload_public_ids: ids)
    end
    assert_includes error.message, "cannot combine"
    assert_equal 3, seen.grep(/\APOST /).length
  end

  def test_the_durable_conversation_primitives_preserve_pages_rows_and_named_fields
    seen = []
    row = { "public_id" => "c-1", "title" => "Research" }
    page = { "conversations" => [row], "pagination" => { "next_after" => "next-2" } }
    announce(endpoint: recording_routed_endpoint(seen, {
      "GET /conversations/detail" => [[200, { "conversation" => row }]],
      "GET /conversations" => [[200, page]],
      "PATCH /conversations" => [[200, { "conversation" => row }]],
      "POST /conversations/archive" => [[200, { "conversation" => row }]],
      "POST /conversations/unarchive" => [[200, { "conversation" => row }]],
      "POST /conversations" => [[201, { "conversation" => row }]],
    }))

    assert_equal page, core.conversations
    assert_equal page, core.conversations(after: "next 2", limit: 12, archived: true)
    assert_equal row, core.conversation("c-1")
    assert_equal row, core.update_conversation("c-1", title: "Research")
    assert_equal row, core.archive_conversation("c-1")
    assert_equal row, core.unarchive_conversation("c-1")
    assert_equal({ "conversation" => row }, core.open_conversation(title: "Research"))

    paths = seen.map { |request| request.lines.first.split[0, 2].join(" ") }
    assert_includes paths, "GET /conversations?after=next+2&limit=12&archived=1"
    assert_includes paths, "GET /conversations/detail?public_id=c-1"
    renamed = seen.find { |request| request.start_with?("PATCH /conversations ") }
    assert_equal({ "public_id" => "c-1", "title" => "Research" }, JSON.parse(renamed.partition("\r\n\r\n").last))
    opened = seen.find { |request| request.start_with?("POST /conversations ") }
    assert_equal "Research", JSON.parse(opened.partition("\r\n\r\n").last).fetch("title")
    assert_equal "", @out.string
  end

  def test_the_conversation_primitives_preserve_the_daemons_typed_refusal
    refusal = [403, { "error" => { "code" => "not_authorized", "message" => "Read access" } }]
    announce(endpoint: routed_endpoint({
      "GET /conversations" => [refusal], "GET /conversations/detail" => [refusal],
      "PATCH /conversations" => [refusal], "POST /conversations/archive" => [refusal],
      "POST /conversations/unarchive" => [refusal],
    }))

    calls = [-> { core.conversations }, -> { core.conversation("c-1") },
             -> { core.update_conversation("c-1", title: "Denied") },
             -> { core.archive_conversation("c-1") }, -> { core.unarchive_conversation("c-1") }]
    calls.each do |call|
      error = assert_raises(Rho::Core::Refused, &call)
      assert_equal [403, "not_authorized", "Read access"], [error.status, error.code, error.message]
    end
  end

  def test_turns_preserves_reverse_windows_and_their_pagination
    seen = []
    document = { "turns" => [], "pagination" => { "before_position" => nil, "after_position" => nil, "has_older" => false } }
    announce(endpoint: recording_routed_endpoint(seen, "GET /conversations/turns" => [[200, document]]))

    assert_equal document, core.turns("c-1", latest: true, limit: 40)
    assert_equal document, core.turns("c-1", before_position: 47, limit: 40)
    assert_equal ["/conversations/turns?public_id=c-1&latest=1&limit=40",
                  "/conversations/turns?public_id=c-1&before_position=47&limit=40"],
      seen.grep(%r{\AGET /conversations/turns}).map { |request| request.lines.first.split[1] }
  end
end
