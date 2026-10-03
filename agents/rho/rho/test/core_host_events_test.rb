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
    reads = seen.grep(%r{\AGET /loops/events\?})
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
    assert_equal "GET /loops/events?public_id=al-1 HTTP/1.1", seen.grep(%r{\AGET /loops/events}).first.lines.first.strip
  end

  def test_host_events_preserves_core_refusals_without_retrying
    seen = []
    announce(endpoint: recording_endpoint(seen, 429,
      { "error" => { "code" => "rate_limited", "message" => "Read later", "retry_after" => 7 } }))

    error = assert_raises(Rho::Core::Refused) { core.host_events("c-1") }

    assert_equal [429, "rate_limited", "Read later"], [error.status, error.code, error.message]
    assert_equal 1, seen.grep(%r{\AGET /loops/events}).length
  end

  def test_a_malformed_success_uses_the_existing_sdk_decoder_guard
    announce(endpoint: recording_endpoint([], 200, page.merge("pagination" => {})))

    error = assert_raises(CybrosAgent::Api::MalformedResponse) { core.host_events("c-1") }

    assert_match "expected next_after", error.message
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
