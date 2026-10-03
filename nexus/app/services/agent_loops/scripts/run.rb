module AgentLoops
  module Scripts
    # Evaluation is pure and outside the loop lock. Publication joins append and
    # settlement in one transaction; a repeated job can compute twice, never publish twice.
    class Run
      class Unstorable < StandardError; end

      # Each expansion is bounded by its own append, but a stage may place a
      # stage, which may place another: one that places its own script again
      # never ends. A stage nested deeper than this fails before it runs.
      MAX_STAGE_DEPTH = 8
      DEPTH_EXCEEDED = "g.script stages nest at most #{MAX_STAGE_DEPTH} deep, and this stage is nested deeper: " \
        "a stage that places its own script again never ends. Place a fixed set of steps, or return a value.".freeze

      def self.call(...) = new(...).call

      def initialize(node:, generation: node.execution_generation)
        @node = node
        @generation = generation
        @agent_loop = node.agent_loop
      end

      def call
        return :not_running unless current_execution?
        return publish { fail_stage(:script_depth_exceeded, DEPTH_EXCEEDED) } if too_deep?

        definition = @node.definition
        results = input_results
        unless Nexus::SizeBounds.json_within?(:snapshot_bound, { "params" => definition.fetch("params"), "results" => results })
          return publish { fail_stage(:script_input_too_large) }
        end

        defaults = definition.fetch("model_defaults")
        built = Nexus::Compose::Evaluator.stage(
          script: definition.fetch("script"), params: definition.fetch("params"), results: results,
          tool_names: Nexus::ToolDeclarations.names(defaults["tools"])
        )
        return publish { fail_stage(built.refusal, built.detail) } unless built.built?
        return publish { complete_value(built.value) } if built.value?

        lowered = Compose::Lower.stage(built: built, node: @node, model_defaults: defaults)
        return publish { fail_stage(lowered.refusal, lowered.detail) } unless lowered.lowered?

        publish { expand(built, lowered) }
      rescue Unstorable, Nexus::CanonicalJson::UnsupportedValue => error
        publish { fail_stage(:result_unstorable, error.message) }
      end

      private

        def current_execution?
          @node.status == "running" && @node.execution_generation == @generation
        end

        def too_deep?
          ExpansionOwnership.stage_depth(@node, limit: MAX_STAGE_DEPTH + 1) > MAX_STAGE_DEPTH
        end

        # One slot per declared key, in order; a race's slot is built from
        # what it selected, whose bodies load in one batch beside the leaves'.
        def input_results
          keys = @node.result_from_node_keys || []
          rows = @agent_loop.agent_loop_nodes.where(node_key: keys).index_by(&:node_key)
          selections = keys.to_h { |key| [key, TaskResultProjection.referenced(rows.fetch(key))] }
          ActiveRecord::Associations::Preloader.new(
            records: selections.values.flatten.uniq, associations: { output_body: { content_body_entries: :content_fragment } }
          ).call
          keys.map { |key| TaskResultProjection.slot(rows.fetch(key), selections.fetch(key)) }
        end

        def publish
          result = @agent_loop.with_lock do
            @node.reload
            next :stale unless current_execution?
            next :not_mutable unless @agent_loop.graph_mutable?

            if @node.deadline_passed?
              Parks::Settle.new(node: @node, timeout: true, trusted: true, release: false).settle_locked
              Release.settled(@node)
              :timed_out
            else
              yield
            end
          end
          ScheduleJob.perform_later(@agent_loop.id) unless %i[stale not_mutable].include?(result)
          result
        end

        def complete_value(value)
          text = Nexus::CanonicalJson.encode(value)
          store_output([{ "text" => text }, { "structured" => value }], text)
          complete
          :completed
        end

        def expand(built, lowered)
          result = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
            agent_loop: @agent_loop, steps: lowered.steps,
            tip: KernelTool.branch_tip(@node), origin: @node.authored_by,
            replaces: @node.node_key, expansion_parent: @node,
            key_generator: -> { SecureRandom.uuid_v7 }
          ))
          unless result.applied?
            error = Compose::Lower.explain(result.errors.first(1), built).first
            detail = error ? JSON.generate(error) : result.outcome
            return fail_stage(:script_expansion_refused, detail)
          end

          keys = result.receipt.fetch("accepted_task_keys")
          text = "Expanded #{keys.length} #{"task".pluralize(keys.length)}: #{keys.join(", ")}."
          store_output([{ "text" => text }], text)
          complete
          :expanded
        end

        def store_output(entries, text)
          stored = ContentBodies::Replace.call(owner: @node, role: "output", entries: entries,
            readable_text: text, seal: true)
          raise Unstorable, stored.refusal.to_s unless stored.accepted?

          StampOutputPreview.call(@node)
        end

        def complete
          Transition.node(@node, status: "completed", completed_at: Time.current,
            output_summary: { "resolved" => true })
          Release.settled(@node)
        end

        def fail_stage(key, detail = nil)
          FailNode.call(agent_loop: @agent_loop, node: @node, error_key: key,
            error_detail: detail, worklist: [])
          :failed
        end
    end
  end
end
