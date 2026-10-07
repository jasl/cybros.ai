require_relative "test_helper"

# Canonical pre-IO measurers. The frozen conservative metrics:
# - `characters` = Unicode scalar values (Ruby codepoints of a UTF-8 string);
# - the token-conservative proxy = UTF-8 byte count (byte-level BPE consumes
#   at least one byte per token, so bytes bound tokens from above — scalars
#   do NOT: one emoji is 1 scalar but can be several tokens).
class TestMeasure < Minitest::Test
  MEASURE = SimpleInference::Measure

  def test_unicode_scalar_count_counts_codepoints
    assert_equal 5, MEASURE.unicode_scalar_count("héllo")
    assert_equal 1, MEASURE.unicode_scalar_count("🎉")
    assert_equal 0, MEASURE.unicode_scalar_count("")
  end

  def test_utf8_byte_count_counts_encoded_bytes
    assert_equal 6, MEASURE.utf8_byte_count("héllo")
    assert_equal 4, MEASURE.utf8_byte_count("🎉")
  end

  def test_utf8_byte_count_rejects_invalid_encoding
    invalid = (+"\xFF\xFE").force_encoding(Encoding::UTF_8)

    assert_raises(SimpleInference::ValidationError) { MEASURE.utf8_byte_count(invalid) }
    assert_raises(SimpleInference::ValidationError) { MEASURE.unicode_scalar_count(invalid) }
  end

  def test_ensure_within_passes_at_the_cap_and_rejects_cap_plus_one
    assert_equal 3, MEASURE.ensure_within(value: 3, cap: 3, bound_id: "speech_input_bytes", unit: "bytes")

    error = assert_raises(SimpleInference::BoundExceededError) do
      MEASURE.ensure_within(value: 4, cap: 3, bound_id: "speech_input_bytes", unit: "bytes")
    end
    assert_includes error.message, "speech_input_bytes"
    assert_includes error.message, "4"
    assert_includes error.message, "3"
  end
end
