module ModelRequests
  # A local advisory estimate: the provider stays authoritative. The counter is a
  # declared registry fact, never inferred from a name, and nothing here touches
  # the network.
  module TokenCount
    Result = Data.define(:tokens, :exact, :refusal) do
      def self.counted(tokens, exact:) = new(tokens: tokens, exact: exact, refusal: nil)
      def self.refused(refusal) = new(tokens: nil, exact: nil, refusal: refusal)

      def counted? = refusal.nil?
      # Whether a real tokenizer counted the text, or an inexact local
      # estimate did. Provider-side framing remains outside this claim.
      def exact? = exact == true
    end

    # A lane declaring an exact counter it cannot load must say that estimation
    # is unavailable instead of silently switching algorithms.
    UNAVAILABLE = :token_counter_unavailable

    # The provider's server-side chat template adds tokens our bytes never
    # contained (measured: 801 tokens for 799 bytes), so the bound carries an allowance.
    ENVELOPE_TOKENS_PER_SEGMENT = 8
    ENVELOPE_TOKENS_FIXED = 8

    class << self
      # Media is not counted: base64 through a text tokenizer is nonsense,
      # not conservatism. It stays bounded by the declared byte limit.
      def count(profile:, segments:)
        counter = profile.token_counter
        counted = if counter.nil?
          byte_upper_bound(segments)
        else
          case counter.kind
          when "tiktoken" then tiktoken_count(counter.encoding, segments)
          when "huggingface" then huggingface_count(counter.tokenizer_id, segments)
          when "anchored" then anchored_count(counter.encoding, counter.safety_factor, segments)
          else Result.refused(UNAVAILABLE)
          end
        end

        with_chat_envelope(counted, profile, segments)
      end

      # Where a `huggingface` counter's tokenizer.json must already be. A
      # pre-download tool writes here; nothing at count time fetches.
      def tokenizer_path(tokenizer_id)
        Rails.root.join("vendor", "tokenizers", "#{tokenizer_id.tr("/", "_")}.json")
      end

      private

        # Provider-side chat framing is outside every local counter, so each
        # gets the same allowance afterward; non-chat workloads add none.
        def with_chat_envelope(counted, profile, segments)
          return counted unless counted.counted?
          return counted unless chat_framed?(profile)

          Result.counted(
            counted.tokens + ENVELOPE_TOKENS_FIXED +
              (ENVELOPE_TOKENS_PER_SEGMENT * segments.length),
            exact: counted.exact
          )
        end

        # Text generation is the only workload whose wire wraps its input in a
        # chat template. Images, speech, transcription and embeddings send
        # what they are given.
        def chat_framed?(profile) = profile.workload == "text_generation"

        # Special tokens count as literal text, the safe side: a pasted
        # `<|endoftext|>` is charged what the escape costs.
        def tiktoken_count(encoding_name, segments)
          encoding = tiktoken_encodings[encoding_name]
          return Result.refused(UNAVAILABLE) if encoding.nil?

          Result.counted(segments.sum { |text| encoding.encode_ordinary(text).length }, exact: true)
        end

        # A tokenizer we can run, times the lane's declared safety factor:
        # the anchor absorbs the content-type swing a byte bound cannot.
        # `exact: false` says it is measured, not proven; rounding is always up.
        def anchored_count(encoding_name, safety_factor, segments)
          anchor = tiktoken_count(encoding_name, segments)
          return anchor unless anchor.counted?

          Result.counted((anchor.tokens * BigDecimal(safety_factor)).ceil, exact: false)
        end

        def huggingface_count(tokenizer_id, segments)
          tokenizer = huggingface_tokenizer(tokenizer_id)
          return Result.refused(UNAVAILABLE) if tokenizer.nil?

          Result.counted(segments.sum { |text| tokenizer.encode(text).ids.length }, exact: true)
        end

        # A byte-level tokenizer emits at most one token per byte. Chat
        # framing is added by the shared route-aware envelope above.
        def byte_upper_bound(segments)
          Result.counted(segments.sum(&:bytesize), exact: false)
        end

        # Loading an encoding costs ~66 ms and tens of MB of vocabulary, so
        # it is memoized per process and never eagerly loaded for lanes this
        # process will not serve.
        def tiktoken_encodings
          @tiktoken_encodings ||= Concurrent::Map.new do |map, name|
            map[name] = begin
              Tiktoken.get_encoding(name)
            rescue StandardError
              nil
            end
          end
        end

        def huggingface_tokenizer(tokenizer_id)
          @huggingface_tokenizers ||= Concurrent::Map.new do |map, id|
            path = tokenizer_path(id)
            map[id] = if File.exist?(path)
              Tokenizers.from_file(path.to_s).tap { |t| t.encode_special_tokens = true }
            end
          end
          @huggingface_tokenizers[tokenizer_id]
        end
    end
  end
end
