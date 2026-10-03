require "test_helper"

# THE ONE VALUE BUILDER: a Data from its typed map over the readers, the map found
# through the include chain. The contexts prove every map against the pack; this pins
# the mechanism's own rules.
class ApiParsingTest < Minitest::Test
  Pair = Data.define(:left, :right)
  Nest = Data.define(:pair, :label, :marks, :rest)

  class Reader
    include CybrosAgent::Api::Parsing
    include CybrosAgent::Api::Fields

    SHAPES = {
      Pair => { left: :string, right: [:optional_integer, "far", "right"] },
      Nest => {
        pair: [:shape, Pair],
        label: :nullable_string,
        marks: [:shapes, Pair, "listed"],
        rest: ->(hash) { hash.keys.sort },
      },
    }.freeze

    def read(klass, hash, key = nil) = shape(klass, hash, key)
    def read_optional(hash, key) = optional_hash(hash, key)
    def read_query(**given) = query(**given)
  end

  Unmapped = Data.define(:x)

  def reader = Reader.new

  def test_a_map_reads_members_by_name_by_path_by_nested_shape_and_by_lambda
    nest = reader.read(Nest, {
      "pair" => { "left" => "l", "far" => { "right" => 2 } },
      "label" => nil,
      "listed" => [{ "left" => "a", "far" => {} }],
      "extra" => true,
    })

    assert_equal Pair.new(left: "l", right: 2), nest.pair
    assert_nil nest.label
    assert_equal [Pair.new(left: "a", right: nil)], nest.marks
    assert_predicate nest.marks, :frozen?
    assert_equal %w[extra label listed pair], nest.rest
  end

  def test_a_keyed_read_unwraps_the_envelope_and_a_keyless_read_wants_an_object
    assert_equal "l", reader.read(Pair, { "pair" => { "left" => "l", "far" => {} } }, "pair").left
    assert_raises(CybrosAgent::Api::MalformedResponse) { reader.read(Pair, nil) }
    assert_raises(CybrosAgent::Api::MalformedResponse) { reader.read(Pair, { "pair" => "text" }, "pair") }
  end

  def test_a_path_names_guaranteed_objects_and_a_nullable_member_must_be_present
    assert_raises(CybrosAgent::Api::MalformedResponse, "far is a guaranteed object") do
      reader.read(Pair, { "left" => "l" })
    end
    assert_raises(CybrosAgent::Api::MalformedResponse, "label is present, null allowed") do
      reader.read(Nest, { "pair" => { "left" => "l", "far" => {} }, "listed" => [] })
    end
  end

  def test_an_unmapped_value_is_a_programmer_error_not_a_malformed_response
    error = assert_raises(ArgumentError) { reader.read(Unmapped, {}) }

    assert_match(/serves no .*Unmapped/, error.message)
  end

  # `optional_hash`: absent and null are nil; a
  # present member of the wrong type is the wire's fault.
  def test_optional_hash_reads_absent_as_nil_and_refuses_a_non_object
    assert_nil reader.read_optional({}, "k")
    assert_nil reader.read_optional({ "k" => nil }, "k")
    assert_equal({ "a" => 1 }, reader.read_optional({ "k" => { "a" => 1 } }, "k"))
    assert_raises(CybrosAgent::Api::MalformedResponse) { reader.read_optional({ "k" => [1] }, "k") }
  end

  # The query builder: a nil keyword sends no parameter, and no parameters
  # send no query at all.
  def test_query_drops_nil_keywords_and_is_nil_when_empty
    assert_nil reader.read_query(after: nil, limit: nil)
    assert_equal({ "after" => "c1", "side" => "1" }, reader.read_query(after: "c1", limit: nil, side: "1"))
  end
end
