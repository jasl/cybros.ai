require "test_helper"

# The committed contracts/nexus/v1 pack must equal what the shipped code
# generates — wire vocabulary drift fails here before any consumer can be
# lied to. Regenerate with `bin/rails contracts:generate`.
class Nexus::ContractTest < ActiveSupport::TestCase
  PACK_ROOT = Rails.root.join("../contracts/nexus/v1")

  test "the committed pack matches the generated contract exactly" do
    rendered = Nexus::Contract.pack.transform_values { |data| Nexus::Contract.render(data) }

    rendered.each do |name, body|
      path = PACK_ROOT.join(name)
      assert path.exist?, "#{name} is missing — run bin/rails contracts:generate"
      assert_equal body, path.read, "#{name} drifted — run bin/rails contracts:generate"
    end

    manifest_path = PACK_ROOT.join("manifest.json")
    assert manifest_path.exist?, "manifest.json is missing — run bin/rails contracts:generate"
    assert_equal Nexus::Contract.render(Nexus::Contract.manifest(rendered)), manifest_path.read

    committed = PACK_ROOT.glob("*.json").map { |path| path.basename.to_s }.sort
    assert_equal (rendered.keys + ["manifest.json"]).sort, committed,
      "the pack directory carries files the generator does not own"
  end

  # Stored digests bake the encoder's byte behavior in, so the encoding is pinned by contract
  # fixtures rather than by an in-process test that would be edited alongside the encoder it guards.
  # The drift check above is what makes changing it a visible breaking migration; these assertions
  # are what make the pinned values mean something.
  test "the content-addressing pack pins real encoder behavior" do
    fixture = Nexus::Contract.pack.fetch("content_addressing.json")
    vectors = fixture.fetch("vectors").index_by { |vector| vector.fetch("name") }

    assert_equal "{account_id}\n{canonical_payload}", fixture.fetch("digest_input")
    assert_equal "0a", fixture.fetch("digest_separator_hex")

    vectors.each_value do |vector|
      address = Nexus::ContentAddress.for(
        account_id: vector.fetch("account_id"), payload: vector.fetch("payload")
      )

      assert_equal vector.fetch("canonical_payload"), address.canonical_payload, vector.fetch("name")
      assert_equal vector.fetch("digest"), address.digest, vector.fetch("name")
      assert_equal vector.fetch("byte_size"), address.byte_size, vector.fetch("name")
    end

    assert_equal %({"0":4,"C":3,"a":2,"b":1}),
      vectors.fetch("key_order_is_normalized").fetch("canonical_payload"),
      "the sorted-key walk is the whole point of a canonical encoding"
    assert_equal vectors.fetch("key_order_is_normalized").fetch("canonical_payload"),
      vectors.fetch("account_salt_changes_the_digest").fetch("canonical_payload")
    assert_not_equal vectors.fetch("key_order_is_normalized").fetch("digest"),
      vectors.fetch("account_salt_changes_the_digest").fetch("digest"),
      "identical bytes in two accounts must never converge to one address"
    assert_equal %({"n":1.5}),
      vectors.fetch("ordinary_decimal_float").fetch("canonical_payload")
    assert_equal %({"n":0.0}),
      vectors.fetch("positive_zero_float").fetch("canonical_payload")
    assert_equal vectors.fetch("positive_zero_float").fetch("canonical_payload"),
      vectors.fetch("negative_zero_float").fetch("canonical_payload")
    assert_equal vectors.fetch("positive_zero_float").fetch("digest"),
      vectors.fetch("negative_zero_float").fetch("digest"),
      "both signs of floating-point zero have one canonical content address"
    assert_equal %({"html":"<tag>&value>"}),
      vectors.fetch("html_sensitive_text").fetch("canonical_payload")
  end

  # Every value the pack tells a second implementation to refuse must actually
  # be refused here, or the fixture documents a contract Nexus does not keep.
  test "the pack's named rejections are the encoder's real refusals" do
    rejections = Nexus::Contract.pack.fetch("content_addressing.json").fetch("rejections")

    number_rejections = {
      "NaN" => Float::NAN,
      "Infinity" => Float::INFINITY,
      "-Infinity" => -Float::INFINITY,
      "finite_exponent_form_float" => 1e308,
    }
    assert_equal number_rejections.keys, rejections.fetch("unsupported_number")
    number_rejections.each_value do |value|
      assert_raises(Nexus::CanonicalJson::UnsupportedNumber) do
        Nexus::CanonicalJson.encode({ "n" => value })
      end
    end

    assert_equal %w[u0000_in_value u0000_in_key invalid_utf8], rejections.fetch("unsupported_text")
    assert_raises(Nexus::CanonicalJson::UnsupportedText) do
      Nexus::CanonicalJson.encode({ "k" => "a\u0000b" })
    end
    assert_raises(Nexus::CanonicalJson::UnsupportedText) do
      Nexus::CanonicalJson.encode({ "a\u0000b" => "k" })
    end
    assert_raises(Nexus::CanonicalJson::UnsupportedText) do
      Nexus::CanonicalJson.encode({ "k" => (+"\xC3\x28").force_encoding(Encoding::UTF_8) })
    end
  end

  test "closed vocabularies cover the states the code actually uses" do
    assert_equal Workspace.states.keys.sort,
      Nexus::Contract.pack.fetch("workspaces.json").fetch("states")
    assert_equal Workspace.access_modes.keys.sort,
      Nexus::Contract.pack.fetch("workspaces.json").fetch("access_modes")
    assert_equal TaskExecutor.executor_kinds.keys.sort,
      Nexus::Contract.pack.fetch("task_executors.json").fetch("executor_kinds")
    assert_equal TaskExecutor.statuses.keys.sort,
      Nexus::Contract.pack.fetch("task_executors.json").fetch("statuses")
    assert_equal Session.kinds.keys.sort,
      Nexus::Contract.pack.fetch("sessions.json").fetch("kinds")
    assert_equal (User.roles.keys - ["system"]).sort,
      Nexus::Contract.pack.fetch("users.json").fetch("roles")
    assert_includes Nexus::Contract.pack.fetch("errors.json").fetch("family_codes"), "stale_object"
    # All five stable credential families export their prefix.
    assert_equal %w[access_token api_session device_code member_recovery refresh_token],
      Nexus::Contract.pack.fetch("credentials.json").fetch("prefixes").keys.sort
  end

  # `Nexus::Contract.verify_version!` went with the 2026-08-15 sweep: its only
  # caller was this test. Nexus is the pack's producer, so it has no version to
  # verify — the CONSUMERS do, and each ships its own reader with its own
  # rejection pin (e2e/test/contract_fixtures_test.rb,
  # sdks/ruby/test/api/public_contract_pack_test.rb).

  test "every coverage entry resolves valid and unknown behavior fixtures" do
    pack = Nexus::Contract.pack
    coverage = pack.fetch("coverage.json")

    %w[protocol_versions closed_discriminators terminal_classes stable_error_families].each do |section|
      entries = coverage.fetch(section)
      assert_predicate entries, :present?

      entries.each do |name, entry|
        assert_predicate entry.fetch("consumers"), :present?, name
        assert_predicate entry.fetch("unknown_behavior"), :present?, name
        refute_nil resolve(pack, entry.fetch("valid_fixture")), name
        refute_nil resolve(pack, entry.fetch("unknown_fixture")), name
      end
    end
  end

  private

    # A JSON pointer, walked the way the spec defines it: a segment
    # against an Array is an INDEX. Hash-only until a contract pointed at
    # a fixture inside a list — the conversation plane publishes its turns
    # and events as one-element pages rather than as bare objects.
    def resolve(pack, reference)
      name, pointer = reference.split("#", 2)
      pointer.to_s.split("/").reject(&:empty?)
        .reduce(pack.fetch(name)) do |value, key|
          value.is_a?(Array) ? value.fetch(Integer(key, 10)) : value.fetch(key)
        end
    end
end
