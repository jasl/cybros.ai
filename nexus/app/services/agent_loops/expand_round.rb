module AgentLoops
  # The kernel drives rounds: inside the converger's transaction, one tool task
  # per call and one continuation that waits on the fan. A round continues iff
  # calls arrived.
  class ExpandRound
    # A tool that could not run reaches the model as an error envelope, so
    # its failure resolves the continuation.
    DEFAULT_FAN_POLICY = "absorb".freeze
    # Names only: the main thread is marked by `continuation_source`, never
    # inferred from a key.
    KEY_PREFIX = "r".freeze

    # A round that could not be authored is a failure, not a quiet no-op: a
    # turn whose continuation cannot exist must not be reported as an answer.
    # It names every expansion refusal, the repeat brake's included.
    EXPANSION_REFUSED = "round_expansion_refused".freeze
    INVALID_ARGUMENTS = "invalid_tool_arguments".freeze
    # The same unparseable string under a round the output budget cut
    # (the envelope): the model reads WHY — the cut, not its JSON — and
    # re-issues the call whole.
    TRUNCATED_ARGUMENTS = "truncated_tool_arguments".freeze
    TRUNCATED_DETAIL = "The tool call could not run: the response hit the output token limit " \
      "and its arguments are incomplete. Re-issue it with complete arguments.".freeze
    # The round asked for a tool it was never offered, or one whose
    # executor has not shipped. Either way nothing can answer it.
    UNKNOWN_TOOL = "unknown_tool".freeze

    class << self
      # A refusal detail, or nil. The gate is graph mutability, not
      # `running`: a graceful pause stops scheduling only and its in-flight
      # step still applies, while a dying graph must not grow.
      def call(agent_loop:, node:)
        return nil unless agent_loop.graph_mutable?

        calls = round_calls(node)
        return nil if calls.empty?

        repeat = RepeatBrake.call(node: node, calls: calls)
        return repeat if repeat

        new(agent_loop, node, calls).expand
      end

      # A round's calls as the repeat brake compares them with the rows: a
      # set of (name, arguments), both sides canonicalized — jsonb does not
      # preserve key order, so raw bytes against a read-back never matched
      # a call with more than one argument — and both sides in the ROW's
      # words: the kernel's wire name and the mapped input, resolved as
      # `fan_steps` resolves them, then `stored` as it stores them. A
      # signature in any other words than the row's could never equal it,
      # and the brake would be blind to that call however identical the
      # rounds. Nil when a call cannot be read.
      def call_signature(node, calls)
        signature = calls.map do |entry|
          name, input, _alias = Nexus::ToolDeclarations.resolve_call(
            node.tool_definitions, entry["name"], parse_arguments(entry["arguments"]) || {}
          )
          name, input = stored(name, input)
          [name.to_s, canonical_arguments(input)]
        end
        signature.sort if signature.none? { |_name, input| input.nil? }
      end

      # WHAT A RESOLVED CALL'S ROW STORES, `[name, input]` — the one rule
      # `fan_steps` authors by and the brake compares by. A name no row can
      # hold is stored as the failure it is given (`UNKNOWN_TOOL`), and an
      # input the row cannot hold — unstorable text or numbers, or over the
      # tool-input bound — as none of its arguments; each such call is failed
      # once it is authored (`fail_undeliverable_calls`).
      def stored(name, input)
        [Tasks::Compile.storable_tool_name?(name.to_s) ? name : UNKNOWN_TOOL,
         unstorable_input_refusal(input) || oversized_input_bytes(input) ? {} : input]
      end

      # Why the row cannot store a resolved input — U+0000 in its text, a
      # number jsonb cannot spell — in the encoder's own words, else nil:
      # the compiler's `invalid_tool_input` judges by the same predicate.
      def unstorable_input_refusal(input) = Nexus::CanonicalJson.storage_refusal(input)

      # A resolved input's size when it is over the tool-input bound, else
      # nil — measured as the row measures it. An input that cannot be
      # encoded at all has no size; it is failed as unstorable instead.
      def oversized_input_bytes(input)
        bytes = Nexus::SizeBounds.json_bytesize(input)
        bytes unless Nexus::SizeBounds.bytes_within?(Tasks::Compile::TOOL_INPUT_BOUND, bytes)
      rescue Nexus::CanonicalJson::UnsupportedValue
        nil
      end

      def canonical_arguments(value)
        Nexus::CanonicalJson.encode(Hash.try_convert(value) || {})
      rescue Nexus::CanonicalJson::UnsupportedText, Nexus::CanonicalJson::UnsupportedNumber
        # A round the brake cannot read is a round it does not judge.
        nil
      end

      def parse_arguments(raw)
        parsed = JSON.parse(raw.to_s)
        Hash.try_convert(parsed)
      rescue JSON::ParserError
        nil
      end

      def round_calls(node)
        invocation_id = node.selected_model_invocation_id
        return [] if invocation_id.nil?

        envelope = ContentBody
          .where(model_invocation_id: invocation_id, role: "tool_calls")
          .includes(content_body_entries: :content_fragment)
          .first&.content_body_entries&.first&.content_fragment&.payload
        Array(envelope && envelope["items"])
      end
    end

    def initialize(agent_loop, node, calls)
      @agent_loop = agent_loop
      @node = node
      @calls = calls
      @round = next_round_number
    end

    # The round's own envelope from its own tip — the fan as one group, the
    # continuation reading the round and the fan — and every queued
    # consumer of the round handed to the continuation in its place.
    def expand
      tip = Tasks::Tip.new(
        spine: Tasks::Known.of(@node), waits: [Tasks::Known.of(@node)], reads: [],
        mark: @node.continuation_source.presence || Tasks::Compile::ROUND,
        detached: @node.detached?, lifetime: @node.lifetime, wake: @node.wake
      )
      result = Tasks::Append.call(Tasks::Append::Command.kernel(
        agent_loop: @agent_loop,
        origin: "model", expansion_parent: @node,
        steps: [Tasks::Step::Parallel.new(members: fan_steps),
                Tasks::Step.inheriting(@node, key: continuation_key)],
        tip: tip, replaces: @node.node_key
      ))
      unless result.applied?
        detail = result.errors.first&.fetch("code", nil) || result.outcome
        Rails.logger.error(
          "event=agent_loop_round_expansion_refused loop=#{@agent_loop.public_id} " \
          "task=#{@node.node_key} calls=#{@calls.length} reason=#{detail}"
        )
        return detail.to_s
      end

      fail_undeliverable_calls
      nil
    end

    private

      def fan_policy = @node.fan_on_failure.presence || DEFAULT_FAN_POLICY

      # THE ONE SITE A MODEL'S CALL BECOMES A ROW, so the one site an alias
      # resolves: the row carries the kernel's wire name and the mapped
      # input, and the model's spelling rides beside them — every reader
      # downstream sees `task`, and rho's rules written against `task`
      # match a call made as `Agent`.
      def fan_steps
        resolved_calls.each_with_index.map do |(name, input, alias_name, entry), index|
          name, input = self.class.stored(name, input)
          Tasks::Step::Tool.new(
            key: fan_key(index), name: name, input: input,
            alias: alias_name, tool_call_id: entry["id"], on_failure: fan_policy
          )
        end
      end

      def resolved_calls
        @resolved_calls ||= @calls.map do |entry|
          name, input, alias_name = Nexus::ToolDeclarations.resolve_call(
            @node.tool_definitions, entry["name"], parsed_arguments(entry) || {}
          )
          [name, input, alias_name, entry]
        end
      end

      # ONE CALL OVER THE TOOL-INPUT BOUND, by index, with its size. Measured
      # on the RESOLVED input, which is what the row stores. Such a call is
      # authored with none of its arguments and failed, like an unparseable
      # one: refusing the batch would turn one oversized write among N good
      # calls into a failed round, and letting it reach `create!` raised
      # inside the converger, which retried the same invocation forever.
      def oversized_bytes
        @oversized_bytes ||= resolved_calls.each_with_index.filter_map do |(_, input, _, _), index|
          bytes = self.class.oversized_input_bytes(input)
          [index, bytes] if bytes
        end.to_h
      end

      # The envelope already opens with "The tool call could not run."
      # (`RoundReplay::Pairing::REASONS`), so the detail starts at WHY.
      def oversized_failure(bytes)
        limit = Nexus::SizeBounds.fetch(Tasks::Compile::TOOL_INPUT_BOUND)
        [Tasks::Compile::TOOL_INPUT_TOO_LARGE,
         "Its arguments are #{delimited(bytes)} bytes, over the #{delimited(limit)} bytes " \
         "one tool call may carry. Re-issue the work as several smaller calls."]
      end

      def delimited(count) = ActiveSupport::NumberHelper.number_to_delimited(count)

      # ONE CALL WHOSE ARGUMENTS THE ROW CANNOT STORE, by index, with the
      # encoder's reason. Authored with none of its arguments and failed like
      # an oversized one: left to the compiler's `invalid_tool_input`, one
      # NUL a model emitted would refuse the whole round and halt the loop.
      def unstorable_refusals
        @unstorable_refusals ||= resolved_calls.each_with_index.filter_map do |(_, input, _, _), index|
          refusal = self.class.unstorable_input_refusal(input)
          [index, refusal] if refusal
        end.to_h
      end

      # The encoder's own sentence, which already says what to do.
      def unstorable_failure(refusal)
        [Tasks::Compile::INVALID_TOOL_INPUT, "#{refusal.upcase_first}."]
      end

      # An unparseable call is still authored — the pairing law owes every
      # call a result — and then failed so the continuation hears why.
      def parsed_arguments(entry)
        parsed = JSON.parse(entry["arguments"].to_s)
        Hash.try_convert(parsed)
      rescue JSON::ParserError
        nil
      end

      def unparseable_indices
        @calls.each_index.reject { |index| parsed_arguments(@calls[index]) }
      end

      # A call is deliverable only if the round DECLARED it — the one gate
      # for a runner's tool and the kernel's alike: the kernel need not know
      # what a runner can do, only what this round offered the model, and a
      # kernel tool the round withheld is refused if guessed, not executed
      # anyway. A name no row can hold is authored under `UNKNOWN_TOOL`
      # (`stored`), so it is never delivered under that stand-in either.
      def undeliverable_indices
        declared = Nexus::ToolDeclarations.names(@node.tool_definitions).to_set
        @calls.each_index.reject do |index|
          name = @calls[index]["name"].to_s
          declared.include?(name) && Tasks::Compile.storable_tool_name?(name)
        end
      end

      # Authored, then failed — never refused: a compile refusal would turn
      # one bad name among N good calls into a human interrupt.
      def fail_undeliverable_calls
        (unparseable_indices.to_a.product([unparseable_failure]) +
          undeliverable_indices.to_a.product([[UNKNOWN_TOOL, nil]]) +
          unstorable_refusals.map { |index, refusal| [index, unstorable_failure(refusal)] } +
          oversized_bytes.map { |index, bytes| [index, oversized_failure(bytes)] }).each do |index, (error_key, detail)|
          node = @agent_loop.agent_loop_nodes.find_by(node_key: fan_key(index))
          next if node.nil? || node.terminal?

          FailNode.call(agent_loop: @agent_loop, node: node, worklist: [],
            error_key: error_key, error_detail: detail)
        end
      end

      # The round's own finish says whether the string is malformed or
      # cut: `ApplyResult` stamped the caveat before the converger ran
      # this driver, so the column is settled when it is read.
      def unparseable_failure
        return [INVALID_ARGUMENTS, nil] unless output_budget_exhausted?

        [TRUNCATED_ARGUMENTS, TRUNCATED_DETAIL]
      end

      def output_budget_exhausted?
        ModelInvocation.find(@node.selected_model_invocation_id).finish_quality ==
          SimpleInference::FinishQuality::OUTPUT_BUDGET_EXHAUSTED
      end

      # Free keys, deterministic given the graph: the driver bumps past
      # anything a client already authored rather than refusing the round.
      def next_round_number
        used = @agent_loop.agent_loop_nodes.pluck(:node_key).to_set
        number = 1
        number += 1 while collides?(used, number)
        number
      end

      def collides?(used, number)
        return true if used.include?("#{KEY_PREFIX}#{number}")

        @calls.each_index.any? { |index| used.include?("#{KEY_PREFIX}#{number}t#{index}") }
      end

      def continuation_key = "#{KEY_PREFIX}#{@round}"

      def fan_key(index) = "#{KEY_PREFIX}#{@round}t#{index}"
  end
end
