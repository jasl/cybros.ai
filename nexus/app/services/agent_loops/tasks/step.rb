module AgentLoops
  module Tasks
    # The step tree every author writes, normalised once from
    # the wire by `from_h` and built directly by the kernel's own authors.
    module Step
      VERBS = %w[tool model ask wait script parallel].freeze

      # A client naming an edge, a barrier or a kernel column is told so by
      # name, never silently ignored — the words the old grammar spelled.
      EDGE_WORDS = %w[
        tasks depends_on input_from kind mode quorum_k loser_policy serial
        join reading detach detachable deliverable window
      ].freeze

      # The wire's `retry` is `retries` here — the SDK's keyword — because a
      # keyword named `retry` cannot be read as a local. A tool step carries
      # no `retry`: the budget was consumed only by the model-step
      # converger, so on a tool it was a silent loss. The budgeted requeue
      # on the settle's failed arm is the recorded alternative if a consumer
      # asks for one. `detached` is the door's per-step word for a step the
      # envelope does not wait for (the node column's word) — never a
      # compose option: a script's WHEN word is `wait` on the call. A fan's
      # join word is `until`: a Ruby keyword, so it is a label, a member and
      # `self.until` here, never a bare local.
      WIRE_FIELDS = {
        "tool" => %w[name input key timeout_ms detached lifetime wake on_failure visibility tool_call_id after],
        "model" => %w[prompt key model tools instructions detached configuration compaction
                      fan_on_failure retry on_failure visibility attachments lifetime wake after results],
        "ask" => %w[prompt options multi key timeout_ms detached lifetime wake on_failure visibility after],
        "wait" => %w[task agent_loop key timeout_ms detached lifetime wake on_failure visibility after],
        "script" => %w[script params key model_defaults detached lifetime wake on_failure visibility after results],
        "parallel" => %w[until losers key on_failure lifetime wake],
      }.freeze

      Refused = Data.define(:code, :path)

      # `alias` is kernel-only, like `tool_call_id`: the spelling the
      # model called a kernel tool under, kept beside the kernel's wire
      # name in `name`; never a wire field.
      Tool = Data.define(:name, :input, :key, :timeout_ms, :detached,
        :on_failure, :visibility, :tool_call_id, :alias, :lifetime, :wake, :after, :lifecycle_event) do
        def initialize(name:, input: {}, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, tool_call_id: nil, alias: nil, lifetime: nil, wake: nil, after: nil,
                       lifecycle_event: nil) = super

        def verb = "tool"
        def kind = "tool_task"
        # A tool call parks on its holder; nothing of it re-runs by budget.
        def retries = nil
        def to_h = { "tool" => Step.wire(super.except(:alias, :lifecycle_event)) }
      end

      # `attachments`: the upload public ids a MODEL step's prompt
      # carries, the member door's word alone — the kernel's own authors
      # never name one, and a model's `compose` cannot (its lowering reads
      # no such key; the agent user holds no uploads).
      Model = Data.define(:prompt, :key, :model, :tools, :instructions, :detached,
        :configuration, :compaction, :fan_on_failure, :retries, :on_failure, :visibility,
        :attachments, :lifetime, :wake, :after, :results) do
        def initialize(prompt: nil, key: nil, model: nil, tools: nil, instructions: nil,
                       detached: false, configuration: nil, compaction: nil,
                       fan_on_failure: nil, retries: nil, on_failure: nil, visibility: nil,
                       attachments: nil, lifetime: nil, wake: nil, after: nil, results: nil) = super

        def verb = "model"
        def kind = "model_task"
        def to_h = { "model" => Step.wire(super) }
      end

      # `options`/`multi` are the question's choices as data: one string
      # each, and whether several may be taken.
      Ask = Data.define(:prompt, :options, :multi, :key, :timeout_ms, :detached, :on_failure, :visibility, :lifetime, :wake, :after) do
        def initialize(prompt: nil, options: nil, multi: nil, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, lifetime: nil, wake: nil, after: nil) = super

        def verb = "ask"
        def kind = "await_task"
        # An ask parks; nothing of it re-runs.
        def retries = nil
        def to_h = { "ask" => Step.wire(super) }
      end

      Wait = Data.define(:task, :agent_loop, :key, :timeout_ms, :detached, :on_failure,
        :visibility, :lifetime, :wake, :after) do
        def initialize(task: nil, agent_loop: nil, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, lifetime: nil, wake: nil, after: nil) = super

        def verb = "wait"
        def kind = "await_task"
        def retries = nil
        def to_h = { "wait" => Step.wire(super) }
      end

      Script = Data.define(:script, :params, :model_defaults, :key, :detached, :on_failure,
        :visibility, :lifetime, :wake, :after, :results) do
        def initialize(script:, params: {}, model_defaults: nil, key: nil, detached: false,
                       on_failure: nil, visibility: nil, lifetime: nil, wake: nil, after: nil, results: nil) = super

        def verb = "script"
        def kind = "script_task"
        def retries = nil
        def to_h = { "script" => Step.wire(super) }
      end

      MODEL_DEFAULT_FIELDS = %w[model configuration tools instructions compaction on_failure fan_on_failure retry].freeze

      # `members` holds steps and nested Arrays of steps (a sequence inside the
      # group); `until` is nil for the default `all`.
      Parallel = Data.define(:members, :until, :losers, :key, :on_failure, :lifetime, :wake) do
        def initialize(members:, until: nil, losers: nil, key: nil, on_failure: nil, lifetime: nil, wake: nil) = super

        def verb = "parallel"
        def kind = "join_task"

        def to_h
          { "parallel" => members.map { |member| Step.wire_tree(member) }, "until" => self.until,
            "losers" => losers, "key" => key, "on_failure" => on_failure, "lifetime" => lifetime, "wake" => wake }.compact
        end
      end

      # The kernel observes one published child request through this node.
      # It is deliberately absent from VERBS and the member wire grammar.
      Delegation = Data.define(:key, :lifetime, :wake, :detached, :on_failure, :visibility) do
        def initialize(key:, lifetime: "turn", wake: nil, detached: true, on_failure: "absorb", visibility: nil) = super

        def verb = "delegation"
        def kind = "delegation_task"
        def retries = nil
        def to_h = { "delegation" => Step.wire(super) }
      end

      class << self
        # The wire, read by shape: one verb key per object, a nested Array as a
        # sequence inside a group. Refuses positionally so the door can name
        # the step that failed.
        def from_h(step, path)
          fields = Hash.try_convert(step) or raise_refused("step_must_be_an_object", path)
          # `to_h` first: an indifferent-access hash re-stringifies symbol keys.
          fields = fields.to_h.transform_keys(&:to_s)
          verbs = fields.keys & VERBS
          raise_refused("ambiguous_step", path) if verbs.length > 1
          raise_refused("unknown_step_verb", path) if verbs.empty?

          verb = verbs.sole
          verb == "parallel" ? parallel_from(fields, path) : task_from(verb, fields[verb], path)
        end

        # A value's members in the wire's spelling.
        def wire(members)
          fields = members.transform_keys(&:to_s)
          fields["retry"] = fields.delete("retries")
          fields.delete("detached") unless fields["detached"]
          fields.compact
        end

        def wire_tree(member)
          sequence = Array.try_convert(member)
          sequence ? sequence.map { |step| wire_tree(step) } : member.to_h
        end

        # The ONE writer of a round's inherited request surface: the model,
        # the submitted options, the tools, the system channel, the policies,
        # and the compaction policy minus the marks a repair left — both are
        # per-round: a continuation inheriting `pruned_before` would compose
        # from rows forever and bust the prefix every round.
        def inheriting(round, **overrides)
          Model.new(**inherited_fields(round).merge(overrides))
        end

        # What a step a round STARTS inherits — a composed member's defaults:
        # the round's surface, on the model its lineage was configured with
        # (ConfiguredModel), never a fallback the round was moved to.
        def model_defaults(round)
          wire(inherited_fields(round).except(:visibility, :lifetime, :wake)
            .merge(model: ConfiguredModel.for(round).model))
        end

        private

          def inherited_fields(round)
            {
              model: { "model" => "#{round.provider_id}/#{round.model_ref}",
                       "reasoning_effort" => round.reasoning_effort }.compact,
              configuration: round.request_options,
              tools: round.tool_definitions,
              instructions: round.system_instructions,
              compaction: round.compaction&.except(
                AgentLoopNodes::ModelTask::SUMMARY_SOURCE, AgentLoopNodes::ModelTask::PRUNED_BEFORE
              ).presence,
              on_failure: round.on_failure,
              fan_on_failure: round.fan_on_failure,
              retries: round.retry_budget,
              visibility: round.transcript_visibility,
              lifetime: round.lifetime, wake: round.wake,
            }
          end

          def task_from(verb, body, path)
            fields = Hash.try_convert(body) or raise_refused("step_must_be_an_object", path)
            fields = fields.to_h.transform_keys(&:to_s)
            refuse_options(verb, fields, "#{path}.#{verb}")
            attributes = fields.to_h { |name, value| [(name == "retry" ? :retries : name.to_sym), value] }
            attributes[:detached] = false if attributes[:detached].nil?
            klass_for(verb).new(**attributes)
          end

          def parallel_from(fields, path)
            members = Array.try_convert(fields["parallel"]) or raise_refused("empty_parallel", path)
            options = fields.except("parallel")
            refuse_options("parallel", options, path)
            Parallel.new(
              members: members.each_with_index.map { |member, index| member_from(member, "#{path}.parallel[#{index}]") },
              **options.transform_keys(&:to_sym)
            )
          end

          def member_from(member, path)
            sequence = Array.try_convert(member)
            return from_h(member, path) if sequence.nil?

            sequence.each_with_index.map { |step, index| from_h(step, "#{path}[#{index}]") }
          end

          def refuse_options(verb, fields, path)
            fields.each_key do |name|
              next if WIRE_FIELDS.fetch(verb).include?(name)

              code = EDGE_WORDS.include?(name) ? "edge_authoring_refused" : "unknown_step_option"
              raise_refused(code, "#{path}.#{name}")
            end
          end

          def klass_for(verb)
            case verb
            when "tool" then Tool
            when "model" then Model
            when "ask" then Ask
            when "wait" then Wait
            when "script" then Script
            else raise ArgumentError, "unknown step verb: #{verb}"
            end
          end

          def raise_refused(code, path) = raise(Refusal.new(Refused.new(code: code, path: path)))
      end

      # The positional refusal, carried out of the tree walk as one exception
      # so the compiler can record it at the step that failed.
      class Refusal < StandardError
        attr_reader :refused

        def initialize(refused)
          @refused = refused
          super("#{refused.code} at #{refused.path}")
        end
      end
    end
  end
end
