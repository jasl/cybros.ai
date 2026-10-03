require "test_helper"

class BoundedJsonValidatorTest < ActiveSupport::TestCase
  class Envelope
    include ActiveModel::API
    attr_accessor :payload, :options

    validates :payload, bounded_json: { bound: :envelope_bound }
    validates :options, bounded_json: { bound: :actor_metadata_bound, shape: Hash }, allow_nil: true
  end

  test "a payload inside its bound is accepted" do
    assert_predicate Envelope.new(payload: { "a" => 1 }), :valid?
  end

  test "a payload past its bound is refused with the registry's rejection" do
    record = Envelope.new(payload: { "text" => "x" * (Nexus::SizeBounds.fetch(:envelope_bound) + 1) })

    assert_not record.valid?
    assert_equal [Nexus::SizeBounds::REJECTION], record.errors.details[:payload].map { |d| d[:error] }
  end

  test "the canonical encoder's refusals become typed errors" do
    number = Envelope.new(payload: { "value" => 1e308 })
    text = Envelope.new(payload: { "value" => "a\u0000b" })

    assert_not number.valid?
    assert_not text.valid?
    assert_equal [:unsupported_number], number.errors.details[:payload].map { |d| d[:error] }
    assert_equal [:unsupported_text], text.errors.details[:payload].map { |d| d[:error] }
  end

  # The encoder's PARENT class is the contract (`callers rescue the parent
  # into their own typed rejection`): a value JSON cannot spell at all — a
  # Symbol, a non-String key — or a structure nested past the substrate's
  # depth is refused typed, never a 500 out of a save.
  test "every other canonical refusal is typed too, not a raised save" do
    symbol = Envelope.new(payload: { "value" => :never })
    key = Envelope.new(payload: { 1 => "one" })
    deep = Envelope.new(payload: 200.times.inject("leaf") { |inner, _| [inner] })

    assert_not symbol.valid?
    assert_not key.valid?
    assert_not deep.valid?
    assert_equal [:unsupported_value], symbol.errors.details[:payload].map { |d| d[:error] }
    assert_equal [:unsupported_value], key.errors.details[:payload].map { |d| d[:error] }
    assert_equal [:unsupported_value], deep.errors.details[:payload].map { |d| d[:error] }
    assert_match(/cannot be stored as JSON/, symbol.errors.full_messages.first)
  end

  test "shape refuses another JSON value before measuring it, and allow_nil skips absence" do
    assert_predicate Envelope.new(payload: nil, options: nil), :valid?
    assert_predicate Envelope.new(payload: nil, options: {}), :valid?

    record = Envelope.new(payload: nil, options: [1])
    assert_not record.valid?
    assert_equal [:invalid], record.errors.details[:options].map { |d| d[:error] }
  end

  test "a declaration without a bound is a programmer error at class load" do
    assert_raises(ArgumentError) do
      Class.new { include ActiveModel::API; attr_accessor :x; validates :x, bounded_json: true }
    end
  end
end
