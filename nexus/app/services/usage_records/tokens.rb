module UsageRecords
  # A WIRE'S TOKEN COUNTS, READ ONCE (the predecessor's normalization, key
  # for key): every spelling a text, image or audio wire uses for input,
  # output, reasoning and the two cache classes, each count through the one
  # boundary a wire number crosses. The receipt prices from it, and a text
  # bench records a call's spend through it, so the two never read one wire
  # two ways. `usage` is the provider's usage hash as the gem hands it back;
  # `adapter_profile` is the wire's, which decides the split-cache fold.
  class Tokens
    # A bound this generous excludes only lies, and keeps the sums built
    # from these members inside bigint by construction.
    WIRE_COUNT_LIMIT = 1_000_000_000_000

    # The spellings a JSON number can take and none it cannot:
    # `Float(String)` alone honours hex literals and underscores.
    WIRE_NUMBER_PATTERN = /\A\d+(?:\.\d+)?(?:[eE]\+?\d+)?\z/

    def self.read(usage, adapter_profile:) = new(usage, adapter_profile).counts

    # The one boundary every wire count crosses: signed, non-finite,
    # radix-prefixed, wrong-typed or absurd reads as absent, which keeps
    # the receipt and the never-under-meter bias both.
    def self.wire_count(value)
      text = value.to_s
      return nil unless text.match?(WIRE_NUMBER_PATTERN)

      number = Float(text, exception: false)
      return nil if number.nil? || !number.finite? || number.negative?

      count = number.to_i
      count > WIRE_COUNT_LIMIT ? nil : count
    end

    def initialize(usage, adapter_profile)
      @usage = begin
        Hash(usage)
      rescue TypeError
        {}
      end
      @adapter_profile = adapter_profile.to_s
    end

    def counts
      raw_input = usage_int("input_tokens", "prompt_tokens", "prompt_token_count")
      cache_read = usage_int(
        "cache_read_input_tokens", "cached_input_tokens", "input_cached_tokens",
        "cached_content_token_count", "prompt_cache_hit_tokens",
        %w[input_tokens_details cached_tokens],
        %w[input_token_details cached_tokens],
        %w[prompt_tokens_details cached_tokens]
      )
      cache_creation = usage_int(
        "cache_creation_input_tokens",
        %w[input_tokens_details cache_write_tokens],
        %w[input_tokens_details cache_creation_tokens],
        %w[prompt_tokens_details cache_write_tokens],
        %w[prompt_tokens_details cache_creation_tokens]
      ) || cache_creation_breakdown
      input = raw_input
      # Anthropic and Bedrock report cache classes BESIDE input_tokens; the
      # normalized count folds them in so every provider's input means
      # the same thing.
      if split_cache_shape?
        input = input.to_i + cache_read.to_i + cache_creation.to_i
      end
      output = usage_int("output_tokens", "completion_tokens",
                         "candidates_token_count", "response_token_count")
      reasoning = usage_int(
        "reasoning_output_tokens", "reasoning_tokens", "thoughts_token_count",
        %w[output_tokens_details thinking_tokens],
        %w[output_tokens_details reasoning_tokens],
        %w[completion_tokens_details reasoning_tokens]
      )
      total = usage_int("total_tokens", "total_token_count") ||
        (input.nil? && output.nil? ? nil : input.to_i + output.to_i)

      # Beyond the persisted six: the 1-hour write share and the
      # image lane's token classes, read for settlement alone.
      { input_tokens: input, output_tokens: output, reasoning_tokens: reasoning,
        cache_read_tokens: cache_read, cache_creation_tokens: cache_creation,
        total_tokens: total,
        cache_creation_1h_tokens: self.class.wire_count(cache_creation_object["ephemeral_1h_input_tokens"]),
        text_input_tokens: usage_int("text_input_tokens"),
        image_input_tokens: usage_int("image_input_tokens"),
        image_output_tokens: usage_int("image_output_tokens") }
    end

    private

      def split_cache_shape?
        %w[anthropic_messages bedrock_converse].include?(@adapter_profile) && (
          @usage.key?("cache_read_input_tokens") ||
            @usage.key?("cache_creation_input_tokens") ||
            cache_creation_object.any?
        )
      end

      # The breakdown members cross the same boundary as every other count
      # (round 2 caught them signed; round 3 caught them oversized).
      def cache_creation_breakdown
        values = %w[ephemeral_5m_input_tokens ephemeral_1h_input_tokens]
          .filter_map { |key| self.class.wire_count(cache_creation_object[key]) }
        values.empty? ? nil : values.sum
      end

      # The wire's cache_creation breakdown, normalized at this boundary the
      # way every other usage member is: whatever is not the expected object
      # reads as empty rather than crashing the receipt.
      def cache_creation_object
        @cache_creation_object ||= begin
          Hash(@usage["cache_creation"])
        rescue TypeError
          {}
        end
      end

      # A hostile wire can put a scalar where a details object belongs, and
      # `dig` raises TypeError on it — one malformed usage member must cost
      # that member, never the receipt.
      def usage_int(*paths)
        paths.filter_map do |path|
          value = begin
            @usage.dig(*Array(path))
          rescue TypeError
            nil
          end
          self.class.wire_count(value)
        end.first
      end
  end
end
