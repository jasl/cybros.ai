require "test_helper"

# The one reading of a wire's token counts, standing alone: the receipt
# prices from it and the text benches record their spend through it, so
# neither may read one wire two ways. The receipt's own suite covers the
# read through a real attempt; these pin the reader a caller without an
# attempt uses.
class UsageRecords::TokensTest < ActiveSupport::TestCase
  Tokens = UsageRecords::Tokens

  test "anthropic reports the cache classes beside input_tokens, and the input folds them in" do
    counts = Tokens.read({ "input_tokens" => 20, "cache_read_input_tokens" => 9_000,
                           "cache_creation_input_tokens" => 150, "output_tokens" => 300 },
      adapter_profile: "anthropic_messages")

    assert_equal [9_170, 300, 9_000, 150, 9_470],
      counts.values_at(:input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens, :total_tokens)
  end

  test "a wire whose input already counts its cached share is never folded" do
    counts = Tokens.read({ "input_tokens" => 9_000, "input_tokens_details" => { "cached_tokens" => 8_192 },
                           "output_tokens" => 40 }, adapter_profile: "openai_responses")

    assert_equal [9_000, 8_192, nil], counts.values_at(:input_tokens, :cache_read_tokens, :cache_creation_tokens)
  end

  test "the 1-hour write share is read from the breakdown, and the breakdown stands in for a missing total" do
    counts = Tokens.read({ "input_tokens" => 10, "output_tokens" => 1,
                           "cache_creation" => { "ephemeral_5m_input_tokens" => 30, "ephemeral_1h_input_tokens" => 70 } },
      adapter_profile: "anthropic_messages")

    assert_equal [100, 70, 110], counts.values_at(:cache_creation_tokens, :cache_creation_1h_tokens, :input_tokens)
  end

  test "a hostile member costs that member, never the reading" do
    counts = Tokens.read({ "input_tokens" => "0x10", "output_tokens" => -3,
                           "input_tokens_details" => "not an object", "prompt_tokens" => 12 },
      adapter_profile: "openai_responses")

    assert_equal [12, nil, nil], counts.values_at(:input_tokens, :output_tokens, :cache_read_tokens)
  end

  test "no usage reads as every count unknown" do
    assert Tokens.read(nil, adapter_profile: "anthropic_messages").values.all?(&:nil?)
  end
end
