require "test_helper"

class Nexus::DigestedSecretTest < ActiveSupport::TestCase
  FAMILY = Nexus::DigestedSecret.new(prefix: "sk-test-v1", digest_salt: "cybros/test/digest")

  test "mint produces a parseable wire credential whose digest matches" do
    parts = FAMILY.mint_parts

    assert parts.raw.start_with?("sk-test-v1-")
    wire = FAMILY.parse(parts.raw)
    assert_equal parts.lookup_id, wire.lookup_id
    assert_equal parts.secret, wire.secret
    assert FAMILY.digest_matches?(parts.digest, lookup_id: wire.lookup_id, secret: wire.secret)
  end

  test "parse is strict before any database traffic" do
    parts = FAMILY.mint_parts

    assert_nil FAMILY.parse(nil)
    assert_nil FAMILY.parse("")
    assert_nil FAMILY.parse(parts.raw + "x")
    assert_nil FAMILY.parse(parts.raw.chop)
    assert_nil FAMILY.parse(parts.raw.sub("sk-test-v1", "sk-other-v1"))
    assert_nil FAMILY.parse(parts.raw.tr(".", "!"))
    # Charset violations of the right length are rejected too.
    assert_nil FAMILY.parse(parts.raw.sub(parts.secret, "!" * Nexus::DigestedSecret::SECRET_LENGTH))
  end

  test "a tampered secret fails the constant-time digest comparison" do
    parts = FAMILY.mint_parts
    tampered = parts.secret.reverse

    assert_not FAMILY.digest_matches?(parts.digest, lookup_id: parts.lookup_id, secret: tampered)
  end

  test "digests are keyed per family salt" do
    sibling = Nexus::DigestedSecret.new(prefix: "sk-test-v1", digest_salt: "cybros/test/other")
    parts = FAMILY.mint_parts

    assert_not_equal parts.digest, sibling.digest(lookup_id: parts.lookup_id, secret: parts.secret)
  end
end
