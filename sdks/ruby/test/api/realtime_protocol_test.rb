require "test_helper"

# The wire vocabulary, which is IO-free on purpose: identifier canonicalization
# is the part a socket cannot help test and the part a subtle bug hides in.
class ApiRealtimeProtocolTest < Minitest::Test
  def setup
    require "cybros_agent/realtime"
  end

  Protocol = -> { CybrosAgent::Realtime::Protocol }

  # CANONICAL, so the same subscription described two ways is one subscription.
  # Duplicate detection is client-side and compares these strings; unsorted or
  # symbol-keyed input would make two identical subscriptions look different
  # and both would be opened.
  def test_the_identifier_is_canonical_regardless_of_how_it_was_written
    symbols = Protocol.().identifier(channel: "C", params: { b: 2, a: 1 })
    strings = Protocol.().identifier(channel: "C", params: { "a" => 1, "b" => 2 })

    assert_equal symbols, strings
    assert_equal '{"a":1,"b":2,"channel":"C"}', symbols
  end

  # A channel ACTION rides the `message` command with its data JSON-encoded
  # inside the frame, as ActionCable's client does; the executor pong is
  # the one this gem sends.
  def test_the_message_command_carries_a_channel_action_as_encoded_data
    frame = JSON.parse(Protocol.().message_command('{"channel":"C"}', { "action" => "pong" }))

    assert_equal "message", frame.fetch("command")
    assert_equal '{"channel":"C"}', frame.fetch("identifier")
    assert_equal '{"action":"pong"}', frame.fetch("data")
  end

  def test_a_param_that_would_redefine_the_channel_is_refused
    assert_raises(ArgumentError) { Protocol.().identifier(channel: "C", params: { channel: "other" }) }
    assert_raises(ArgumentError) do
      Protocol.().identifier(channel: "C", params: { "_cybros_sdk_subscription_id" => "mine" })
    end
  end

  def test_a_key_that_collides_after_stringification_is_refused
    assert_raises(ArgumentError) { Protocol.().identifier(channel: "C", params: { a: 1, "a" => 2 }) }
  end

  # THE NONCE IS WHY RESUBSCRIBING IS SAFE. ActionCable routes by the complete
  # raw identifier, so a resubscribe to the same channel with the same params
  # is indistinguishable from its predecessor — and a late frame from the dying
  # one would be delivered to its replacement.
  def test_the_wire_identifier_carries_a_fresh_nonce_each_time
    identifier = Protocol.().identifier(channel: "C", params: { a: 1 })
    first = JSON.parse(Protocol.().wire_identifier(identifier))
    second = JSON.parse(Protocol.().wire_identifier(identifier))

    refute_equal first.fetch("_cybros_sdk_subscription_id"),
      second.fetch("_cybros_sdk_subscription_id")
    assert_equal({ "a" => 1, "channel" => "C" }, first.except("_cybros_sdk_subscription_id"),
      "the logical subscription must survive the nonce unchanged")
  end

  # ONE BAD FRAME MUST NOT KILL THE PUMP. Every other frame on that socket
  # belongs to some other subscription.
  def test_an_unparseable_frame_is_dropped_rather_than_raised
    assert_nil Protocol.().parse_frame("not json")
    assert_nil Protocol.().parse_frame("[1,2]")
    assert_equal({ "type" => "ping" }, Protocol.().parse_frame('{"type":"ping"}'))
  end
end
