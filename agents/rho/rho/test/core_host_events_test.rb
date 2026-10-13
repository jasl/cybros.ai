require "test_helper"

class CoreHostEventsTest < Minitest::Test
  include RhoTest::CliHarness

  def test_host_events_reads_one_typed_page_with_the_exact_cursor_and_limit
    seen = []
    announce(endpoint: recording_endpoint(seen, 200, page))

    result = core.host_events("c-1", after: "opaque/+==", limit: 3)

    assert_instance_of CybrosAgent::Api::ConversationEventPage, result
    assert_equal "next/+==", result.next_after
    assert_equal 12, result.watermark
    assert_equal 1, result.items.length
    event = result.items.first
    assert_equal ["ev-8", 8, "cursor-8", "future_event", "conversation", "c-1"],
      [event.public_id, event.sequence, event.cursor, event.type, event.resource_type, event.resource_public_id]
    assert_equal "2026-09-20T00:00:00Z", event.occurred_at
    assert_equal({ "input_public_id" => "input-1", "nested" => [false, nil, { "value" => "kept" }] }, event.payload)
    reads = seen.grep(%r{\AGET /runs/events\?})
    assert_equal 1, reads.length
    query = URI.decode_www_form(URI.parse(reads.first.split[1]).query).to_h
    assert_equal({ "public_id" => "c-1", "after" => "opaque/+==", "limit" => "3" }, query)
    assert_equal "", @out.string
  end

  def test_omitted_options_leave_paging_defaults_to_nexus
    seen = []
    announce(endpoint: recording_endpoint(seen, 200,
      { "events" => [], "pagination" => { "next_after" => nil, "watermark" => 0 } }))

    result = core.host_events("al-1")

    assert_empty result.items
    assert_nil result.next_after
    assert_equal 0, result.watermark
    assert_equal "GET /runs/events?public_id=al-1 HTTP/1.1", seen.grep(%r{\AGET /runs/events}).first.lines.first.strip
  end

  def test_host_events_preserves_core_refusals_without_retrying
    seen = []
    announce(endpoint: recording_endpoint(seen, 429,
      { "error" => { "code" => "rate_limited", "message" => "Read later", "retry_after" => 7 } }))

    error = assert_raises(Rho::Core::Refused) { core.host_events("c-1") }

    assert_equal [429, "rate_limited", "Read later"], [error.status, error.code, error.message]
    assert_equal 1, seen.grep(%r{\AGET /runs/events}).length
  end

  def test_a_malformed_success_uses_the_existing_sdk_decoder_guard
    announce(endpoint: recording_endpoint([], 200, page.merge("pagination" => {})))

    error = assert_raises(CybrosAgent::Api::MalformedResponse) { core.host_events("c-1") }

    assert_match "expected next_after", error.message
  end

  def test_input_materialization_reads_the_original_execution_through_the_typed_sdk_projection
    seen = []
    value = { "input_public_id" => "input-1", "turn_public_id" => "turn-1",
      "variant_public_id" => "original", "run_public_id" => "run-1" }
    announce(endpoint: recording_endpoint(seen, 200, { "materialization" => value }))

    result = core.input_materialization("c-1", input_public_id: "input-1", workspace_public_id: "ws-original")

    assert_instance_of CybrosAgent::Api::InputMaterialization, result
    assert_equal value, result.to_h.transform_keys(&:to_s)
    read = seen.grep(%r{\AGET /conversations/input_materialization\?}).first
    query = URI.decode_www_form(URI.parse(read.split[1]).query).to_h
    assert_equal({ "public_id" => "c-1", "input_public_id" => "input-1", "workspace_public_id" => "ws-original" }, query)
  end

  def test_input_materialization_absence_does_not_invent_an_execution
    announce(endpoint: recording_endpoint([], 200, { "materialization" => nil }))

    assert_nil core.input_materialization("c-1", input_public_id: "input-1")
  end

  def test_input_materialization_preserves_refusal_without_retrying
    seen = []
    announce(endpoint: recording_endpoint(seen, 403,
      { "error" => { "code" => "not_authorized", "message" => "Not authorized" } }))

    error = assert_raises(Rho::Core::Refused) { core.input_materialization("c-1", input_public_id: "input-1") }

    assert_equal [403, "not_authorized"], [error.status, error.code]
    assert_equal 1, seen.grep(%r{\AGET /conversations/input_materialization\?}).length
  end

  private

    def page
      { "events" => [{
        "public_id" => "ev-8", "sequence" => 8, "cursor" => "cursor-8", "type" => "future_event",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-20T00:00:00Z",
        "payload" => { "input_public_id" => "input-1", "nested" => [false, nil, { "value" => "kept" }] },
      }], "pagination" => { "next_after" => "next/+==", "watermark" => 12 } }
    end
end
