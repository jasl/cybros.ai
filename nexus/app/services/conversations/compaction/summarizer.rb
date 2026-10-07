module Conversations
  module Compaction
    # THE ONE SUMMARIZER TASK, built for either host — a value builder,
    # never a second arm. `kernel` is a tool-less model step reading the
    # rendered history under the declaring profile's `summarizer` slot, else
    # the one INSTRUCTIONS; `delegate` hands the same rendering to the
    # agent's own tool as a tool_task. Neither carries a pairing key, so
    # both splice as material rather than history.
    class Summarizer
      MODE_DELEGATE = "delegate".freeze
      # The room a `tool_input` has. The bound is the registry's; the
      # headroom is the clamp's FIRST GUESS at the address, the two field
      # names and the escaping — never the guarantee, which only measuring
      # the encoded envelope can give (`Serialize.clamp_pair`).
      DELEGATED_BOUND = :envelope_bound
      DELEGATED_HEADROOM = 2.kilobytes
      RETRIES = 2
      # The window fit converges in two or three counts; a bound on the
      # passes, never on the material.
      FIT_PASSES = 6
      # Absorb, so a failed repair cannot poison the round it repairs; the
      # kernel's own step carries its retries too, because absorb resolves
      # a failure the moment it is written — no retry door reopens it —
      # and a round is repaired at most once. A delegated tool call has no
      # budget: it parks on the agent's own handler.
      POLICY = { on_failure: "absorb", visibility: "collapsed" }.freeze

      # ONE text for both hosts. The sections are the coding agent's shape
      # led by the conversation's two; the re-read section replaces the
      # "critical context … verbatim" paragraph that invited a flash-tier
      # summariser to write values it could not have — tool output reaches
      # it as pointers, and the kernel frames the summary with REREAD_RULE.
      INSTRUCTIONS = <<~TEXT.strip.freeze
        You are compacting the transcript of a conversation so it can
        continue in a smaller context. Write a summary that lets the work
        resume with nothing important lost.

        Cover, as sections: what the user is trying to ACHIEVE, the
        CONSTRAINTS and preferences they have stated, the GOAL of the work
        in hand, what has been DONE, the DECISIONS taken and why, what
        remains as NEXT STEPS, and WHAT TO RE-READ.

        WHAT TO RE-READ: list every file, command output and tool result
        the work depends on as a POINTER — its path or the call that
        produced it — and NEVER reproduce its contents, values, lines or
        numbers: tool output in the transcript above is shown as pointers
        for this reason, and a value you write from memory will be wrong.
        Say plainly which results are not in this summary. Likewise an
        attachment appears as a pointer with its filename; name it, never
        describe what it showed. Preserve exact file PATHS and identifiers
        you were given; never invent one.

        Write only the summary; no commentary about summarizing.
      TEXT

      # `model`/`reasoning_effort` are the host's own — the round's, or the
      # selection's between turns — under the policy's override; `address`
      # is the model-facing address of what a delegate summarizes;
      # `selection` is the reader when the host already holds it; `tools`
      # is the host's DECLARED SET (the repaired round's, or the answering
      # agent's between turns), whose model-facing names — an alias by its
      # alias — lead the kernel's request. A delegate's tool knows its own
      # tools and is handed none. `profile` is the DECLARING PROFILE (the
      # loop's mid-turn, the conversation's between turns): its
      # `summarizer` slot is the kernel step's text, else INSTRUCTIONS —
      # resolved once, read at the step and by the window fit alike; the
      # delegate arm never reads it.
      def initialize(key:, policy:, account:, model:, reasoning_effort:, address:, reasoning_enabled: nil,
                     selection: nil, tools: nil, profile: nil)
        @key = key
        @policy = policy
        @account = account
        @model = policy["model"].presence || model
        @reasoning_effort = policy["reasoning_effort"].presence || (reasoning_effort if @model == model)
        @reasoning_enabled = ActiveModel::Type::Boolean.new.cast(
          policy.fetch("reasoning_enabled", (reasoning_enabled if @model == model))
        )
        @address = address
        @selection = selection
        @tool_names = Nexus::ToolDeclarations.names(tools)
        @instructions = slot_text(profile) || INSTRUCTIONS unless policy["mode"] == MODE_DELEGATE
      end

      # The text the kernel step will carry: the profile's slot, else the default.
      attr_reader :instructions

      def step(entries, older, tail)
        return delegated(older, tail) if @policy["mode"] == MODE_DELEGATE

        summarized(*fitted(entries, older, tail))
      end

      private

        def summarized(older, tail)
          AgentRuns::Tasks::Step::Model.new(
            key: @key,
            model: { "model" => @model, "reasoning_effort" => @reasoning_effort,
                     "reasoning_enabled" => @reasoning_enabled }.compact,
            instructions: @instructions, prompt: request(older, tail), retries: RETRIES, **POLICY
          )
        end

        # A delegated repair rides a tool_input, a smaller room than a
        # prompt, so it is clamped oldest-first — the tail the summarizer
        # is told to keep specific goes last.
        def delegated(older, tail)
          # The address rides the same tool_input and counts against the
          # same bound, so the clamp is measured with it.
          older, tail = Serialize.clamp_pair(older, tail, DELEGATED_BOUND, @address)
          AgentRuns::Tasks::Step::Tool.new(
            key: @key, name: @policy["tool_name"],
            input: @address.merge("history" => older, "retained_tail" => tail),
            **POLICY
          )
        end

        # THE SUMMARIZER MUST FIT THE WINDOW OF THE MODEL THAT READS IT. The
        # byte bound is the storage wall; a history that walled is, by
        # construction, larger than the window on the lane that walled it,
        # and the scheduler's pre-send gate would fail the step on size
        # where the lane counts exactly. So on a lane that counts, the
        # older section shrinks — whole entries, oldest first, under the
        # elision marker — until the request counts under the bound; the
        # tail never yields. No counter or no window: nothing to fit to,
        # and the provider's refusal stays the gate.
        def fitted(entries, older, tail)
          profile, bound = window
          return [older, tail] if profile.nil?

          fixed = ModelRequests::TokenCount.count(profile: profile, segments: [@instructions, request("", tail)])
          # Instructions and the retained tail are not ours to discard. If
          # those alone exhaust the window, leave the ordinary gate to refuse.
          return [older, tail] unless fixed.counted? && fixed.tokens < bound

          room = older.bytesize
          FIT_PASSES.times do
            counted = ModelRequests::TokenCount.count(
              profile: profile, segments: [@instructions, request(older, tail)]
            )
            break unless counted.counted? && counted.tokens > bound && older.present?

            room = [(room * (bound - fixed.tokens) / (counted.tokens - fixed.tokens).to_f).floor,
              older.bytesize - 1].min
            break unless room.positive?

            older, tail = Serialize.call(entries, room: room)
          end
          [older, tail]
        end

        # The one request both the step and the fit count: the names lead it.
        def request(older, tail) = Serialize.request(older, tail, tools: @tool_names)

        # The profile's own summarizer text, nil when none is written (or
        # the host has no declaring profile — a human-answered conversation).
        def slot_text(profile)
          profile&.prompt_documents&.find_by(slot: PromptDocument::SUMMARIZER_SLOT)&.content
        end

        # The reader's profile and window, resolved as the scheduler will
        # resolve the step's; nil when the lane declares no counter or no
        # window. The selection in hand is the reader unless the policy
        # names another model.
        def window
          selection = @selection if @selection && @policy["model"].blank?
          selection ||= ModelSelection.resolve(
            account: @account,
            workload: "text_generation",
            submitted: Nexus::SubmittedModelSelection.new(model: @model, reasoning_effort: @reasoning_effort,
              reasoning_enabled: @reasoning_enabled),
            configuration: InferenceRequests::CoerceConfiguration.call({}),
            port: ModelSelection::Resolver.new
          ).then { |resolved| resolved.selection if resolved.resolved? }
          return nil if selection.nil?

          # The summary is scheduled through the same planning gate as its
          # reader; fitting only the hard limit can make the repair itself fail.
          bound = selection.capabilities.limits.planning_input_bound
          profile = selection.execution_profile
          [profile, bound] unless bound.nil? || profile.token_counter.nil?
        end
    end
  end
end
