require "test_helper"

# Wire JSON arrives as Hashes; the acceptance grammar judges typed messages
# and refuses raw Hashes on purpose (plan M3). This is the one seam that turns
# one into the other, and the property that matters is that it never widens
# what may be sent: a shape it does not recognize must reach the boundary
# unchanged, so the boundary is still the only judge.
class OneShots::CoerceTextMessagesTest < ActiveSupport::TestCase
  WIRE = [
    { "role" => "user", "parts" => [{ "type" => "text", "text" => "hi" }] },
    { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "hello" }] },
  ].freeze

  def coerce(input) = OneShots::CoerceTextMessages.call(input)

  def accepted?(input)
    ModelSelection::Workloads.normalize_input(
      workload: "text_generation", input: coerce(input)
    ).accepted?
  end

  test "wire messages become the typed values the grammar judges" do
    coerced = coerce(WIRE)

    assert_equal 2, coerced.length
    assert_kind_of Nexus::TextInputMessage, coerced.first
    assert_equal "user", coerced.first.role
    assert_kind_of Nexus::TextInputPart, coerced.first.parts.first
    assert_equal "hi", coerced.first.parts.first.text
    assert accepted?(WIRE)
  end

  # A String input is a whole other accepted shape and passes through: the
  # seam coerces, it does not reinterpret.
  test "shapes that are not message arrays pass through untouched" do
    assert_equal "just text", coerce("just text")
    assert_nil coerce(nil)
    assert_equal({ "not" => "an array" }, coerce({ "not" => "an array" }))
  end

  # Every one of these is refused today. If coercion ever invents a role, a
  # part type, or a missing field, one of them starts being accepted — which
  # is exactly the widening this seam must not do.
  test "malformed wire messages stay refused after coercion" do
    [
      [{ "role" => "user" }],
      [{ "parts" => [{ "type" => "text", "text" => "hi" }] }],
      [{ "role" => "user", "parts" => [] }],
      [{ "role" => "user", "parts" => "hi" }],
      [{ "role" => "user", "parts" => [{ "type" => "image", "text" => "hi" }] }],
      [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "" }] }],
      [{ "role" => "wizard", "parts" => [{ "type" => "text", "text" => "hi" }] }],
      [{ "role" => "user", "parts" => [{ "type" => "text" }] }],
      ["not a message"],
      [nil],
      # A recognizable parts Array holding something unrecognizable: coercing
      # the message anyway would hand the digest a typed value it cannot
      # serialize, and the caller would get a server fault instead of this
      # refusal.
      [{ "role" => "user", "parts" => ["bare string"] }],
      [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "ok" }, 42] }],
    ].each do |wire|
      assert_not accepted?(wire), "#{wire.inspect} must stay refused"
    end
  end

  # Unknown members are dropped rather than carried: the typed value is the
  # allowlist, so a caller cannot smuggle a field past the grammar.
  test "unknown members do not survive coercion" do
    coerced = coerce([
      { "role" => "user", "name" => "smuggled",
        "parts" => [{ "type" => "text", "text" => "hi", "cache" => true }] },
    ])

    assert_equal %w[role parts], coerced.first.to_h.keys
    assert_equal %w[type text], coerced.first.parts.first.to_h.keys
  end

  test "upload references are canonicalized once at the wire boundary" do
    canonical = "019fbe00-0000-7000-8000-00000000000a"
    coerced = coerce([
      {
        "role" => "user",
        "parts" => [
          { "type" => "upload", "upload_public_id" => canonical.upcase },
          { "type" => "upload", "upload_public_id" => "{#{canonical}}" },
          { "type" => "upload", "upload_public_id" => "not-a-uuid" },
        ],
      },
    ])

    assert_equal [canonical, canonical, nil],
      coerced.sole.parts.map(&:upload_public_id)
  end

  test "coercion is idempotent over already typed messages" do
    once = coerce(WIRE)

    assert_equal once, coerce(once)
  end
end
