require "test_helper"
require_relative "support/contract_fixtures"

# THE BOUND AND THE MEASURE ARE THE PACK'S: `ENVELOPE_BOUND` is
# `size_bounds.json`'s value, in bytes, and the canonical measure renders
# every vector of `content_addressing.json` byte for byte — key order
# normalized, escapes and non-ASCII as the kernel spells them, a zero
# float as `0.0` — so a caller's verdict before the PUT is the kernel's
# verdict on it.
class SizeBoundsTest < Minitest::Test
  def test_the_envelope_bound_is_the_packs
    entry = CybrosAgentTest::ContractFixtures.pack("size_bounds.json").fetch("bounds").fetch("envelope_bound")
    assert_equal({ "unit" => "bytes", "value" => CybrosAgent::SizeBounds::ENVELOPE_BOUND }, entry)
  end

  def test_the_canonical_measure_renders_every_vector_of_the_pack
    vectors = CybrosAgentTest::ContractFixtures.pack("content_addressing.json").fetch("vectors")
    refute_empty vectors
    vectors.each do |vector|
      canonical = JSON.generate(CybrosAgent::SizeBounds.canonical(vector.fetch("payload")))
      assert_equal vector.fetch("canonical_payload"), canonical, vector.fetch("name")
      assert_equal vector.fetch("byte_size"), CybrosAgent::SizeBounds.canonical_bytesize(vector.fetch("payload")), vector.fetch("name")
    end
  end

  def test_symbol_keys_measure_as_the_strings_the_wire_carries
    assert_equal CybrosAgent::SizeBounds.canonical_bytesize({ "b" => 1, "a" => [2] }),
      CybrosAgent::SizeBounds.canonical_bytesize({ b: 1, a: [2] })
  end
end
