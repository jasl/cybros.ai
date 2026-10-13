require "test_helper"

class Nexus::CanonicalJsonTest < ActiveSupport::TestCase
  test "encodes objects with codepoint-sorted keys and no insignificant whitespace" do
    value = { "b" => 1, "a" => { "d" => [2, { "f" => 5, "e" => 4 }], "c" => 3 } }

    assert_equal %({"a":{"c":3,"d":[2,{"e":4,"f":5}]},"b":1}), Nexus::CanonicalJson.encode(value)
  end

  test "two objects differing only in key insertion order encode identically" do
    first = { "outer" => { "a" => 1, "b" => 2 } }
    second = { "outer" => { "b" => 2, "a" => 1 } }

    assert_equal Nexus::CanonicalJson.encode(first), Nexus::CanonicalJson.encode(second)
  end

  test "digest hashes the canonical bytes through one generator" do
    first = { "b" => 2, "a" => 1 }
    second = { "a" => 1, "b" => 2 }

    assert_equal "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777",
      Nexus::CanonicalJson.digest(first)
    assert_equal Nexus::CanonicalJson.digest(first), Nexus::CanonicalJson.digest(second)
  end

  test "encodes scalars as bare JSON" do
    assert_equal "null", Nexus::CanonicalJson.encode(nil)
    assert_equal "true", Nexus::CanonicalJson.encode(true)
    assert_equal "false", Nexus::CanonicalJson.encode(false)
    assert_equal "42", Nexus::CanonicalJson.encode(42)
    assert_equal "1.5", Nexus::CanonicalJson.encode(1.5)
    assert_equal %("text"), Nexus::CanonicalJson.encode("text")
  end

  test "normalizes signed floating-point zero" do
    assert_equal "0.0", Nexus::CanonicalJson.encode(-0.0)
    assert_equal Nexus::CanonicalJson.encode(0.0), Nexus::CanonicalJson.encode(-0.0)
  end

  test "preserves array element order" do
    assert_equal %([3,1,2]), Nexus::CanonicalJson.encode([3, 1, 2])
  end

  test "emits raw UTF-8 bytes and bytesize counts them" do
    encoded = Nexus::CanonicalJson.encode({ "k" => "汉字" })

    assert_equal %({"k":"汉字"}), encoded
    assert_equal encoded.bytesize, Nexus::CanonicalJson.bytesize({ "k" => "汉字" })
    assert_equal 8 + 6, Nexus::CanonicalJson.bytesize({ "k" => "汉字" })
  end

  test "rejects non-String object keys" do
    error = assert_raises ArgumentError do
      Nexus::CanonicalJson.encode({ symbol: 1 })
    end

    assert_match(/String/, error.message)
  end

  test "rejects values outside the JSON vocabulary" do
    assert_raises ArgumentError do
      Nexus::CanonicalJson.encode(Time.now)
    end
    assert_raises ArgumentError do
      Nexus::CanonicalJson.encode({ "k" => Object.new })
    end
  end

  test "rejects non-finite floats" do
    assert_raises ArgumentError do
      Nexus::CanonicalJson.encode(Float::NAN)
    end
    assert_raises ArgumentError do
      Nexus::CanonicalJson.encode({ "k" => Float::INFINITY })
    end
  end

  test "rejects floats whose pinned encoding uses exponent notation" do
    [1e308, 1e-308].each do |value|
      error = assert_raises Nexus::CanonicalJson::UnsupportedNumber do
        Nexus::CanonicalJson.encode({ "value" => value })
      end

      assert_match(/string/, error.message)
    end
  end
  # PostgreSQL's text and jsonb cannot store U+0000, and an acceptance grammar
  # that asks only "is this a present String" will hand one straight through.
  # Catching it here is what keeps it from aborting the INSERT of whatever
  # aggregate was being formed.
  test "rejects text carrying U+0000, in a value or in a key" do
    [{ "value" => "a\u0000b" }, { "a\u0000b" => "value" }].each do |payload|
      assert_raises Nexus::CanonicalJson::UnsupportedText do
        Nexus::CanonicalJson.encode(payload)
      end
    end
  end

  test "rejects a string that is not valid UTF-8" do
    invalid = (+"ab").force_encoding(Encoding::BINARY) << 255.chr
    invalid.force_encoding(Encoding::UTF_8)
    assert_not invalid.valid_encoding?

    assert_raises Nexus::CanonicalJson::UnsupportedText do
      Nexus::CanonicalJson.encode({ "value" => invalid })
    end
  end

  # Codepoints the substrate CAN store must not be swept up with it.
  test "carries control characters and noncharacters PostgreSQL accepts" do
    assert_equal %q({"value":"a\u0001b"}), Nexus::CanonicalJson.encode({ "value" => "a\u0001b" })
  end

  # Both limitations answer to one rescue, so a caller converts them into its
  # own typed rejection without knowing which arrived.
  test "both limitations share one parent" do
    assert_operator Nexus::CanonicalJson::UnsupportedNumber, :<, Nexus::CanonicalJson::UnsupportedValue
    assert_operator Nexus::CanonicalJson::UnsupportedText, :<, Nexus::CanonicalJson::UnsupportedValue
  end

  # AND SO DOES THE THIRD, which is the one a real provider actually hands us.
  #
  # A caller that means "store this if it can be stored" rescues the parent
  # and records nothing otherwise. That contract held for every value this
  # encoder had ever been handed until an OpenRouter turn arrived carrying
  # `usage.cost` as a BigDecimal — the gem decodes that lane's decimals as
  # BigDecimal on purpose, so a binary Float cannot silently drop wire digits
  # — and the unknown-class branch raised a BARE ArgumentError that no such
  # rescue names. The receipt writer's rescue listed all three known classes
  # and still missed it, so the whole attempt died and the turn hung in
  # `running` instead of degrading.
  test "an unsupported class answers to the same rescue" do
    error = assert_raises(Nexus::CanonicalJson::UnsupportedValue) do
      Nexus::CanonicalJson.encode({ "cost" => BigDecimal("5.4e-7") })
    end
    assert_match(/BigDecimal/, error.message)
  end

  # The key path is the same promise on the other axis.
  test "an unsupported key class answers to the same rescue" do
    assert_raises(Nexus::CanonicalJson::UnsupportedValue) do
      Nexus::CanonicalJson.encode({ 1 => "one" })
    end
  end

  test "nesting past the substrate's depth answers to the same rescue" do
    deep = 200.times.inject("x") { |value, _| { "k" => value } }

    error = assert_raises(Nexus::CanonicalJson::UnsupportedDepth) { Nexus::CanonicalJson.encode(deep) }
    assert_kind_of Nexus::CanonicalJson::UnsupportedValue, error
  end

  # THE ONE ANSWER TO "CAN THE ROW STORE HOLD THIS": the step compiler asks it
  # of every structured field it writes, and a reader outside the application
  # asks the same predicate rather than a copy of it.
  test "storable? refuses what the row store cannot hold and admits ordinary JSON" do
    assert Nexus::CanonicalJson.storable?({ "path" => "app/models/user.rb", "lines" => [1, 2.5, nil, true] })
    assert Nexus::CanonicalJson.storable?("text with a \\ backslash and 汉字")

    refute Nexus::CanonicalJson.storable?("a\u0000b"), "a real U+0000 in a string"
    refute Nexus::CanonicalJson.storable?({ "outer" => [{ "inner" => "a\u0000b" }] }), "one nested in a Hash"
    refute Nexus::CanonicalJson.storable?({ "a\u0000b" => 1 }), "one in a key"
    refute Nexus::CanonicalJson.storable?({ "n" => Float::INFINITY }), "a number the encoder refuses"
    refute Nexus::CanonicalJson.storable?({ "n" => 1e308 }), "an exponent-form number"
    invalid = (+"ab").force_encoding(Encoding::BINARY) << 255.chr
    refute Nexus::CanonicalJson.storable?(invalid.force_encoding(Encoding::UTF_8)), "text that is not UTF-8"
  end

  # TODAY'S RULE, PINNED AS IT STANDS: the six characters `\u0000` written as
  # text — a backslash, then "u0000" — are refused as well, though jsonb
  # holds them (it refuses only the escape that decodes to U+0000). An
  # over-refusal deferred as its own item: a change here lands with a jsonb
  # round-trip test beside it, never on its own.
  test "storable? refuses the escape text for U+0000 as well" do
    refute Nexus::CanonicalJson.storable?("see \\u0000 in the dump"),
      "the escape-text over-refusal is today's rule; changing it is the deferred escape-text item, with its jsonb round-trip test"
  end

  # The same answer with its reason, for a caller that hands the reason on: the
  # round driver fails a model's unstorable call with it, so the model reads why.
  test "storage_refusal names the encoder's reason, and nil for what the row can hold" do
    assert_nil Nexus::CanonicalJson.storage_refusal({ "path" => "app/models/user.rb" })
    assert_equal Nexus::CanonicalJson::UNSTORABLE_CODEPOINT_REFUSAL,
      Nexus::CanonicalJson.storage_refusal({ "script" => "a\u0000b" })
    assert_equal Nexus::CanonicalJson::UNSTORABLE_CODEPOINT_REFUSAL,
      Nexus::CanonicalJson.storage_refusal("see \\u0000 in the dump"), "the over-refusal speaks as the codepoint"
    assert_includes Nexus::CanonicalJson.storage_refusal({ "n" => 1e308 }), "encode the value as a string"
  end
end
