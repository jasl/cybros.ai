require "minitest/autorun"
require "frame_codec"

# The Ruby suite for lib/frame_codec.rb, translated case for case from the
# JavaScript codec's behaviour in src/frame_codec.js. Every byte string is
# binary (`.b`); every expected value was produced by the JavaScript.
class FrameCodecTest < Minitest::Test
  def frame(kind, payload) = FrameCodec::Frame.new(kind: kind, payload: payload.b)

  def damaged(reason, skipped) = FrameCodec::Damaged.new(reason: reason, skipped: skipped)

  # A segment framed by hand: flags around the escaped content plus its crc,
  # so a test can put a kind or a length on the wire that encode_frame refuses.
  def raw_frame(content)
    crc = FrameCodec.crc16(content)
    "\x7E".b + FrameCodec.escape(content + [crc].pack("n")) + "\x7E".b
  end

  # ---- varint --------------------------------------------------------------

  def test_varint_encodes_small_values_in_one_byte
    assert_equal "\x00".b, FrameCodec.encode_varint(0)
    assert_equal "\x7F".b, FrameCodec.encode_varint(127)
  end

  def test_varint_encodes_larger_values_low_group_first
    assert_equal "\x80\x01".b, FrameCodec.encode_varint(128)
    assert_equal "\xAC\x02".b, FrameCodec.encode_varint(300)
    assert_equal "\xFF\xFF\xFF\xFF\x0F".b, FrameCodec.encode_varint(0xFFFFFFFF)
  end

  def test_varint_round_trips_and_reports_where_it_ended
    [0, 1, 127, 128, 300, 16_383, 16_384, 2**31, 2**32 - 1].each do |value|
      encoded = FrameCodec.encode_varint(value)
      assert_equal [value, encoded.bytesize], FrameCodec.decode_varint(encoded), "value #{value}"
    end
  end

  def test_varint_decodes_at_an_offset
    assert_equal [300, 3], FrameCodec.decode_varint("\x01\xAC\x02".b, 1)
  end

  def test_varint_refuses_out_of_range_and_unreadable_input
    assert_raises(FrameCodec::VarintError) { FrameCodec.encode_varint(-1) }
    assert_raises(FrameCodec::VarintError) { FrameCodec.encode_varint(2**32) }
    assert_raises(FrameCodec::VarintError) { FrameCodec.decode_varint("\x80".b) }
    assert_raises(FrameCodec::VarintError) { FrameCodec.decode_varint("\x80\x80\x80\x80\x80\x01".b) }
  end

  # ---- crc16 ---------------------------------------------------------------

  def test_crc16_is_ccitt_false
    assert_equal 0x29B1, FrameCodec.crc16("123456789".b)
    assert_equal 0xFFFF, FrameCodec.crc16("".b)
  end

  def test_crc16_sees_a_single_bit
    refute_equal FrameCodec.crc16("hello".b), FrameCodec.crc16("hellp".b)
  end

  # ---- escaping ------------------------------------------------------------

  def test_escape_doubles_only_the_four_reserved_bytes
    assert_equal "\x7D\x5E\x7D\x5D\x7D\x31\x7D\x33".b, FrameCodec.escape("\x7E\x7D\x11\x13".b)
    assert_equal "plain".b, FrameCodec.escape("plain".b)
  end

  def test_unescape_reverses_escape_over_every_byte_value
    every_byte = (0..255).to_a.pack("C*")
    assert_equal every_byte, FrameCodec.unescape(FrameCodec.escape(every_byte))
  end

  def test_unescape_refuses_a_bare_flag_a_dangling_escape_and_a_bad_pair
    assert_raises(FrameCodec::EscapeError) { FrameCodec.unescape("ab\x7Ecd".b) }
    assert_raises(FrameCodec::EscapeError) { FrameCodec.unescape("ab\x7D".b) }
    assert_raises(FrameCodec::EscapeError) { FrameCodec.unescape("\x7D\x41".b) }
  end

  # ---- encoding ------------------------------------------------------------

  def test_encode_frame_lays_out_flag_kind_length_payload_crc_flag
    assert_equal "\x7E\x01\x02hi\xE3\x18\x7E".b, FrameCodec.encode_frame(1, "hi".b)
  end

  def test_encode_frame_escapes_a_reserved_payload_byte
    encoded = FrameCodec.encode_frame(2, "a\x7Eb".b)
    assert_equal 2, encoded.count("\x7E".b), "only the two flags are bare"
    assert_includes encoded, "\x7D\x5E".b
  end

  def test_encode_frame_escapes_a_reserved_length_byte
    encoded = FrameCodec.encode_frame(3, "x".b * 126)
    assert_equal "\x7E\x03\x7D\x5E".b, encoded.byteslice(0, 4), "a length of 0x7e goes out escaped"
    assert_equal 2, encoded.count("\x7E".b)
    assert_equal [frame(3, "x" * 126)], FrameCodec.decode_frames(encoded)
  end

  def test_encode_frame_refuses_a_bad_kind_or_an_oversized_payload
    assert_raises(ArgumentError) { FrameCodec.encode_frame(-1, "".b) }
    assert_raises(ArgumentError) { FrameCodec.encode_frame(128, "".b) }
    assert_raises(ArgumentError) { FrameCodec.encode_frame(1, "x".b * (FrameCodec::MAX_PAYLOAD + 1)) }
  end

  # ---- decoding ------------------------------------------------------------

  def test_decode_frames_round_trips_one_frame
    assert_equal [frame(7, "payload")], FrameCodec.decode_frames(FrameCodec.encode_frame(7, "payload".b))
  end

  def test_an_empty_payload_and_a_full_one_round_trip
    assert_equal [frame(0, "")], FrameCodec.decode_frames(FrameCodec.encode_frame(0, "".b))
    full = Array.new(FrameCodec::MAX_PAYLOAD) { |i| i % 256 }.pack("C*")
    assert_equal [frame(127, full)], FrameCodec.decode_frames(FrameCodec.encode_frame(127, full))
  end

  def test_decode_frames_reads_consecutive_frames_with_a_shared_or_a_doubled_flag
    a = FrameCodec.encode_frame(1, "a".b)
    b = FrameCodec.encode_frame(2, "b".b)
    assert_equal [frame(1, "a"), frame(2, "b")], FrameCodec.decode_frames(a + b.byteslice(1..))
    assert_equal [frame(1, "a"), frame(2, "b")], FrameCodec.decode_frames(a + b)
  end

  def test_decode_frames_reports_a_crc_error_and_resyncs_on_the_next_flag
    bad = FrameCodec.encode_frame(1, "abc".b)
    bad.setbyte(3, bad.getbyte(3) ^ 0x01)
    good = FrameCodec.encode_frame(2, "b".b)
    assert_equal [damaged("crc", 7), frame(2, "b")], FrameCodec.decode_frames(bad + good)
  end

  def test_decode_frames_reports_a_length_that_disagrees_with_the_body
    assert_equal [damaged("length", 6)], FrameCodec.decode_frames(raw_frame("\x01\x05ab".b))
    assert_equal [damaged("length", 1)], FrameCodec.decode_frames("\x7E\x01\x7E".b)
  end

  def test_decode_frames_reports_a_bad_escape
    assert_equal [damaged("escape", 2)], FrameCodec.decode_frames("\x7E\x7D\x41\x7E".b)
  end

  def test_decode_frames_reports_a_kind_above_127
    over = raw_frame(FrameCodec.encode_varint(200) + "\x00".b)
    assert_equal [damaged("kind", 5)], FrameCodec.decode_frames(over)
  end

  def test_decode_frames_ignores_idle_flags_and_noise_before_the_first_flag
    stream = "junk".b + "\x7E\x7E\x7E".b + FrameCodec.encode_frame(4, "ok".b) + "\x7E".b
    assert_equal [frame(4, "ok")], FrameCodec.decode_frames(stream)
  end

  def test_decode_frames_drops_a_trailing_partial_frame
    assert_equal [], FrameCodec.decode_frames(FrameCodec.encode_frame(1, "abc".b).byteslice(0..-2))
  end

  # ---- the incremental reader ---------------------------------------------

  def test_reader_completes_a_frame_split_across_feeds
    reader = FrameCodec::Reader.new
    encoded = FrameCodec.encode_frame(1, "split".b)
    assert_equal [], reader.feed(encoded.byteslice(0, 3))
    assert_equal 2, reader.pending
    assert_equal [frame(1, "split")], reader.feed(encoded.byteslice(3..))
    assert_equal 0, reader.pending
  end

  def test_reader_gives_up_on_an_overlong_segment_and_recovers
    reader = FrameCodec::Reader.new
    overlong = "\x7E".b + ("a".b * (FrameCodec::MAX_SEGMENT_BYTES + 1))
    assert_equal [damaged("length", FrameCodec::MAX_SEGMENT_BYTES + 1)], reader.feed(overlong)
    assert_equal 0, reader.pending
    assert_equal [frame(2, "b")], reader.feed(FrameCodec.encode_frame(2, "b".b))
  end

  def test_reader_reset_forgets_a_partial_frame
    reader = FrameCodec::Reader.new
    reader.feed("\x7E\x01\x02".b)
    reader.reset
    assert_equal 0, reader.pending
  end
end
