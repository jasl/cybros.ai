module Runs
  module Tasks
    # The step tree every author writes, normalised once from
    # the wire by `from_h` and built directly by the kernel's own authors.
    module Step
      VERBS = %w[tool model ask wait parallel].freeze

      # A client naming an edge, a barrier or a kernel column is told so by
      # name, never silently ignored — the words the old grammar spelled.
      EDGE_WORDS = %w[
        tasks depends_on input_from kind mode quorum_k loser_policy serial
        join reading detach detachable deliverable window
      ].freeze

      # `detached` is the per-step word for work the envelope does not wait
      # for. A fan's join word is `until`: a Ruby keyword, so it is a label,
      # a member and `self.until` here, never a bare local.
      WIRE_FIELDS = {
        "tool" => %w[name input route key timeout_ms detached lifetime wake on_failure visibility tool_call_id after model_defaults],
        "model" => %w[prompt key model workload tools instructions detached configuration compaction
                      fan_on_failure on_failure visibility attachments lifetime wake after results
                      kernel_tools runner_executor_public_ids runner_tool_names mcp_tools model_selection fallback_models],
        "ask" => %w[prompt options multi key timeout_ms detached lifetime wake on_failure visibility after],
        "wait" => %w[task run_public_id key timeout_ms detached lifetime wake on_failure visibility after],
        "parallel" => %w[until losers key on_failure lifetime wake],
      }.freeze

      Refused = Data.define(:code, :path)

      # `alias` is kernel-only, like `tool_call_id`: the spelling the
      # model called a kernel tool under, kept beside the kernel's wire
      # name in `name`; never a wire field.
      Tool = Data.define(:name, :input, :route, :key, :timeout_ms, :detached,
        :on_failure, :visibility, :tool_call_id, :alias, :lifetime, :wake, :after, :lifecycle_event, :model_defaults) do
        def initialize(name:, input: {}, route: nil, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, tool_call_id: nil, alias: nil, lifetime: nil, wake: nil, after: nil,
                       lifecycle_event: nil, model_defaults: nil) = super

        def verb = "tool"
        def kind = "tool_task"
        def to_h = { "tool" => Step.wire(super.except(:alias, :lifecycle_event)) }
      end

      # `attachments`: upload public ids beside a member-authored model
      # step's prompt, resolved against the append command's creator.
      # Kernel-authored steps, including task-continuation children, refuse
      # them because their append command carries no member upload authority.
      Model = Data.define(:prompt, :key, :model, :workload, :tools, :instructions, :detached,
        :configuration, :compaction, :fan_on_failure, :on_failure, :visibility,
        :attachments, :lifetime, :wake, :after, :results, :environment,
        :kernel_tools, :runner_executor_public_ids, :runner_tool_names, :mcp_tools, :model_selection, :fallback_models, :resolved_uploads) do
        def initialize(prompt: nil, key: nil, model: nil, workload: "text_generation", tools: nil, instructions: nil,
                       detached: false, configuration: nil, compaction: nil,
                       fan_on_failure: nil, on_failure: nil, visibility: nil,
                       attachments: nil, lifetime: nil, wake: nil, after: nil, results: nil, environment: nil,
                       kernel_tools: nil, runner_executor_public_ids: nil, runner_tool_names: nil, mcp_tools: nil,
                       model_selection: nil, fallback_models: nil, resolved_uploads: nil) = super

        def verb = "model"
        def kind = "model_task"
        def to_h
          fields = super.except(:environment, :resolved_uploads)
          fields.delete(:workload) if workload == "text_generation"
          { "model" => Step.wire(fields) }
        end
      end

      # `options`/`multi` are the question's choices as data: one string
      # each, and whether several may be taken.
      Ask = Data.define(:prompt, :options, :multi, :key, :timeout_ms, :detached, :on_failure, :visibility, :lifetime, :wake, :after) do
        def initialize(prompt: nil, options: nil, multi: nil, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, lifetime: nil, wake: nil, after: nil) = super

        def verb = "ask"
        def kind = "await_task"
        def to_h = { "ask" => Step.wire(super) }
      end

      Wait = Data.define(:task, :run_public_id, :key, :timeout_ms, :detached, :on_failure,
        :visibility, :lifetime, :wake, :after) do
        def initialize(task: nil, run_public_id: nil, key: nil, timeout_ms: nil, detached: false,
                       on_failure: nil, visibility: nil, lifetime: nil, wake: nil, after: nil) = super

        def verb = "wait"
        def kind = "await_task"
        def to_h = { "wait" => Step.wire(super) }
      end

      MODEL_DEFAULT_FIELDS = %w[model workload configuration tools instructions compaction on_failure fan_on_failure
                               kernel_tools runner_executor_public_ids runner_tool_names mcp_tools model_selection fallback_models].freeze

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
        def to_h = { "delegation" => Step.wire(super) }
      end

      # Existing owned work may be joined without authoring arbitrary edges.
      # The executor boundary supplies resolved sources; this is not a wire verb.
      Barrier = Data.define(:sources, :until, :losers, :key, :on_failure, :lifetime, :wake) do
        def initialize(sources:, until: "all", losers: nil, key: nil, on_failure: "absorb",
                       lifetime: nil, wake: nil) = super

        def verb = "barrier"
        def kind = "join_task"
        def to_h = { "barrier" => Step.wire(super.merge(sources: sources.map(&:key))) }
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
              workload: round.workload,
              model: { "model" => "#{round.provider_id}/#{round.model_ref}",
                       "reasoning_effort" => round.reasoning_effort,
                       "reasoning_enabled" => round.reasoning_enabled }.compact,
              configuration: round.request_options,
              model_selection: round.model_selection&.as_json,
              fallback_models: round.fallback_models,
              tools: round.tool_definitions,
              environment: round.operation_context&.fetch("environment", nil),
              instructions: round.system_instructions,
              compaction: round.compaction&.except(
                ::Tasks::ModelTask::SUMMARY_SOURCE, ::Tasks::ModelTask::PRUNED_BEFORE
              ).presence,
              on_failure: round.on_failure,
              fan_on_failure: round.fan_on_failure,
              visibility: round.transcript_visibility,
              lifetime: round.lifetime, wake: round.wake,
            }
          end

          def task_from(verb, body, path)
            fields = Hash.try_convert(body) or raise_refused("step_must_be_an_object", path)
            fields = fields.to_h.transform_keys(&:to_s)
            refuse_options(verb, fields, "#{path}.#{verb}")
            if verb == "tool" && fields.key?("route")
              word = Nexus::ToolRoute.refusal(fields["route"])
              raise_refused(word, "#{path}.#{verb}.route") if word
            end
            attributes = fields.transform_keys(&:to_sym)
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
