module Nexus
  module PromptCache
    # The sole placer of cache_control markers: the STABLE marker on the
    # last item of the stable prefix — the last system block when the
    # wire's system field is present (Anthropic renders tools → system →
    # messages, so one marker caches both), else the leading run of
    # system-role items in the list plus at most one user-role item after
    # it (the assembler's slots, then its memory block) — and the rolling
    # TAIL on the last block of the final input entry, this round's prefix
    # for the next. The anthropic_messages wire's alone (Build reads the
    # lowering's breakpoint fact, gated by the profile's `prompt_caching` —
    # on for every text wire, `false` the opt-out). The tail rides under
    # replayed reasoning too: Anthropic preserves prior-turn thinking
    # blocks in the cached prefix and never strips them inside a tool-use
    # loop, so a loop replaying its own thinking is exactly where the
    # history cache pays. The one skip is a thinking-LAST block (Anthropic
    # 400s a marker on it), reported as `tail: false` on the Placement,
    # never silently. The TIER and whether a tail is written at all are the
    # request's kind (RequestKind, stamped at its mint): a request nobody
    # extends writes its stable head alone.
    module Breakpoints
      # Anthropic's own two `cache_control.ttl` spellings; `5m` is the
      # default marker with no `ttl` key, byte for byte.
      TIERS = %w[5m 1h].freeze
      # The Anthropic per-request cap. Two markers (stable + tail) are
      # emitted, so this is a backstop: a future third source can never
      # silently overflow the wire cap.
      MAX_BREAKPOINTS = 4
      # Anthropic rejects cache_control on these (400); a non-cacheable tail
      # block skips the breakpoint rather than being marked or relocated.
      NON_CACHEABLE_BLOCK_TYPES = %w[thinking redacted_thinking].freeze

      # The decision AND the marked structures, so the seam logs from the
      # one computation instead of re-deriving policy predicates — the
      # evidence line can never disagree with what was placed. `tail` is
      # whether the rolling marker was asked for and LANDED: false when the
      # request writes none, or the final block cannot carry one (a
      # thinking-last assistant turn, an empty list).
      Placement = Data.define(:instructions, :input, :capable, :enabled, :tail, :tier)

      module_function

      def apply(instructions:, input:, capable:, tier:, tail: true)
        unless capable
          return Placement.new(instructions:, input:, capable: false,
            enabled: false, tail: false, tier: tier)
        end

        marker(tier)
        system_present = system_source_present?(instructions)
        marked, landed = mark_messages(input, stable_at: (stable_index(input) unless system_present),
          placed: system_present ? 1 : 0, tier: tier, tail: tail)
        Placement.new(
          instructions: system_present ? mark_system(instructions, tier) : instructions,
          input: marked, capable: true, enabled: true, tail: landed, tier: tier
        )
      end

      # BOTH markers of one request take the request's tier; a mixed
      # request is a shape no probe has validated.
      def marker(tier)
        case tier
        when "5m" then { "type" => "ephemeral" }.freeze
        when "1h" then { "type" => "ephemeral", "ttl" => "1h" }.freeze
        else raise ArgumentError, "prompt-cache tier #{tier.inspect} is not one of #{TIERS.join(", ")}"
        end
      end

      def system_source_present?(instructions)
        case instructions
        when Array then instructions.any?
        when String then !instructions.strip.empty?
        else false
        end
      end

      # THE STABLE PREFIX by the list's role structure: the leading run of
      # system-role items, then at most one user-role item directly after it
      # — memory when memory exists, else the first history turn, as stable
      # as history is. A developer-role item there — the oldest turn's
      # preface in history, a first turn's lead, a template's own
      # developer block — ends the run at the system items: identical
      # bytes stay cached behind the rolling tail marker, and nothing that
      # moves is ever marked stable. No leading run (today's standalone
      # shape; a pruned round opening with its summary) marks item 0 — the
      # one licensed bust, once per wall. Nil for an empty list.
      def stable_index(input)
        entries = Array.try_convert(input)
        return nil if entries.nil? || entries.empty?

        run = entries.take_while { |entry| role_of(entry) == "system" }.length
        return run if run < entries.length && role_of(entries[run]) == "user"

        [run - 1, 0].max
      end

      def role_of(entry)
        Hash.try_convert(entry)&.fetch("role", nil).to_s
      end

      # A String system lowers to one structured block; an Array marks its
      # last block.
      def mark_system(instructions, tier)
        case instructions
        when Array
          replace_at(instructions, instructions.length - 1) do |block|
            ephemeral_system_block(block, tier)
          end
        when String then [ephemeral_text_block(instructions, tier)]
        else instructions
        end
      end

      # `placed` counts markers the system arm already emitted, so the
      # guard enforces the WIRE cap, not a message-only subcount. Answers
      # `[marked, tail]`: the list and whether the rolling marker landed
      # on its last entry — a skip is reported, never swallowed; a request
      # that asked for no tail answers false.
      def mark_messages(input, stable_at:, tier:, placed: 0, tail: true)
        return [input, false] unless Array.try_convert(input)&.any?

        tail_at = input.length - 1 if tail
        targets = [stable_at, tail_at].compact.uniq
        if placed + targets.length > MAX_BREAKPOINTS
          raise ArgumentError,
            "prompt-cache placement would emit #{placed + targets.length} " \
            "breakpoints (max #{MAX_BREAKPOINTS})"
        end

        marked = targets.reduce(input) { |carried, index| mark_message_at(carried, index, tier) }
        [marked, !tail_at.nil? && !mark_entry(input[tail_at], tier).nil?]
      end

      def mark_message_at(input, index, tier)
        marked = mark_entry(input[index], tier)
        marked.nil? ? input : replace_at(input, index) { marked }
      end

      # A function_call_output carries the marker on the entry (forwarded onto
      # the tool_result block). Entries that cannot carry one cleanly answer
      # nil so the breakpoint is skipped rather than reshaping the request.
      def mark_entry(entry, tier)
        return with_marker(entry, tier) if entry["type"].to_s == "function_call_output"
        return nil unless entry.key?("content")

        case entry["content"]
        when Array then mark_content_list(entry, tier)
        when String then mark_content_string(entry, tier)
        # Any other shape is one this policy does not know how to mark
        # cleanly, so the breakpoint is skipped rather than guessed at.
        else nil
        end
      end

      def mark_content_list(entry, tier)
        content = entry["content"]
        return nil if content.empty?

        marked = mark_content_part(content.last, tier)
        return nil if marked.nil?

        entry.merge("content" => replace_at(content, content.length - 1) { marked })
      end

      def mark_content_string(entry, tier)
        text = entry["content"]
        return nil if text.strip.empty?

        entry.merge("content" => [ephemeral_text_block(text, tier)])
      end

      # nil when the block is a non-cacheable position, signalling the
      # caller to SKIP this breakpoint.
      def mark_content_part(part, tier)
        return nil if NON_CACHEABLE_BLOCK_TYPES.include?(part["type"].to_s)

        with_marker(part, tier)
      end

      # A system block is the request's declared union: bare text or a
      # {text, cache_control} block.
      def ephemeral_system_block(block, tier)
        case block
        when String then ephemeral_text_block(block, tier)
        when Hash then with_marker(block, tier)
        else block
        end
      end

      # The only two places that know what a marked block looks like.
      def ephemeral_text_block(text, tier)
        { "type" => "text", "text" => text, "cache_control" => marker(tier) }
      end

      def with_marker(hash, tier) = hash.merge("cache_control" => marker(tier))

      # Immutable element replace (the house rule): a new array, never a
      # mutation of the caller's frozen request material.
      def replace_at(array, index)
        array.each_with_index.map { |element, position| position == index ? yield(element) : element }
      end
    end
  end
end
