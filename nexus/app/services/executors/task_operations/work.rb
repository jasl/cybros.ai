module Executors
  module TaskOperations
    class Work
      Step = AgentRuns::Tasks::Step
      Append = AgentRuns::Tasks::Append

      def initialize(node:, request:)
        @node = node
        @loop = node.agent_run
        @request = request
      end

      def call
        kind = @request.fetch("kind")
        fields = kind == "tool" ? %w[kind name input timeout_ms] : %w[kind input]
        unknown = @request.keys - fields
        refuse(:unknown_fields, "unknown operation fields: #{unknown.join(", ")}") if unknown.any?

        case kind
        when "tool"
          append([{ "tool" => @request.slice("name", "input", "timeout_ms") }])
        when "model", "ask", "wait"
          append([{ @request.fetch("kind") => input }])
        when "steps"
          append(step_input)
        when "background"
          input.key?("operation_key") ? release : append(step_input, background: true)
        when "replace"
          replace
        when "cancel"
          cancel
        when "join"
          join
        else
          refuse(:unknown_operation, "unknown operation kind: #{@request.fetch("kind")}")
        end
      end

      private

        def input
          @input ||= Hash.try_convert(@request.fetch("input", {})) ||
            refuse(:invalid_input, "operation input must be an object")
        end

        def step_input
          value = @request["input"]
          Array.try_convert(value) || input["steps"]
        end

        def tip(background: false, waits: [])
          AgentRuns::Tasks::Tip.seed(AgentRuns::Tasks::Compile::BRANCH,
            lifetime: background ? input.fetch("lifetime", "conversation") : @node.lifetime,
            wake: background ? input.fetch("wake", @node.wake) : @node.wake)
            .with(waits: waits, detached: background || @node.detached?)
        end

        def append(steps, background: false, waits: [], replaces: nil)
          start = tip(background: background, waits: waits)
          unless AgentRunTask::LIFETIMES.include?(start.lifetime) && AgentRunTask::WAKE_MODES.include?(start.wake)
            refuse(:invalid_lifetime, "background lifetime/wake is invalid")
          end
          append_steps(Lower.new(@node).call(steps), start: start, replaces: replaces, background: background)
        end

        def append_steps(steps, start: tip, replaces: nil, background: false)
          result = Append.call_locked(Append::Command.kernel(agent_run: @loop, steps: steps, tip: start,
            origin: @node.authored_by, expansion_parent: @node, child_work: true,
            key_generator: -> { SecureRandom.uuid_v7 }, replaces: replaces))
          unless result.applied?
            message = result.errors.any? ? JSON.generate(result.errors) : result.outcome.to_s
            refuse(result.outcome, message)
          end
          receipt = result.receipt
          { "receipt" => {
            "task_keys" => receipt.fetch("accepted_task_keys"),
            "result_task_keys" => receipt.fetch("result_task_keys"),
            "steps" => receipt.fetch("steps"), "keys" => receipt.fetch("keys"),
            "background" => background,
          } }
        end

        def target_operation(key)
          record = @node.task_operations.find_by(operation_key: key.to_s)
          refuse(:unknown_operation, "operation #{key.inspect} was not accepted by this task") unless record&.response&.key?("receipt")
          record
        end

        def targets
          receipt = target_operation(input["operation_key"]).response.fetch("receipt")
          names = input["tasks"]
          keys = if names
            names = Array.try_convert(names) || refuse(:invalid_tasks, "tasks must be an array")
            names.map do |name|
              receipt.fetch("keys", {}).fetch(name.to_s, name.to_s)
            end
          else
            receipt.fetch("task_keys")
          end
          unless keys.any? && (keys - receipt.fetch("task_keys")).empty?
            refuse(:task_not_owned, "tasks must name work accepted by the selected operation")
          end
          @loop.agent_run_tasks.where(node_key: keys).order(:id).to_a
        end

        def replace
          selected = targets
          unless selected.any? && selected.all? { |row| AgentRunTask::PRE_DISPATCH_STATUSES.include?(row.status) }
            refuse(:task_already_started, "replacement accepts only work that has not started")
          end
          ids = selected.map(&:id)
          sources = AgentRunTask.joins(:outgoing_edges)
            .where(agent_run_edges: { to_node_id: ids }).where.not(id: ids).distinct.to_a
          response = append(input["steps"], waits: sources.map { |row| AgentRuns::Tasks::Known.of(row) },
            replaces: selected.map(&:node_key))
          AgentRuns::CancelBranch.cancel_locked(agent_run: @loop, targets: selected)
          response
        end

        def cancel
          selected = targets
          rows = selected.flat_map { |row| [row, *AgentRuns::ExpansionOwnership.descendants(row)] }.uniq(&:id)
          AgentRuns::CancelBranch.cancel_locked(agent_run: @loop, targets: rows)
          { "receipt" => { "task_keys" => [], "result_task_keys" => rows.map(&:node_key),
            "steps" => [], "keys" => {}, "canceled_task_keys" => rows.map(&:node_key) } }
        end

        def release
          target = target_operation(input["operation_key"])
          receipt = target.response.fetch("receipt")
          lifetime = input.fetch("lifetime", "conversation")
          wake = input.fetch("wake", @node.wake)
          unless AgentRunTask::LIFETIMES.include?(lifetime) && AgentRunTask::WAKE_MODES.include?(wake)
            refuse(:invalid_lifetime, "background lifetime/wake is invalid")
          end
          rows = @loop.agent_run_tasks.where(node_key: receipt.fetch("task_keys")).to_a
          rows = rows.flat_map { |row| [row, *AgentRuns::ExpansionOwnership.descendants(row)] }.uniq(&:id)
          # An explicit ownership transfer is the only rewrite of these authored
          # slots. Completed facts stay intact; later expansions inherit the
          # live parent's transferred lifetime. The operation receipt records
          # which results are released from this task's result boundary.
          @loop.agent_run_tasks.where(id: rows.map(&:id), status: AgentRunTask::LIVE_STATUSES)
            .update_all(detached: true, lifetime: lifetime, wake: wake, updated_at: Time.current)
          @loop.touch
          { "receipt" => { "task_keys" => [], "result_task_keys" => receipt.fetch("result_task_keys"),
            "steps" => [], "keys" => {}, "background" => true,
            "released_operations" => [target.operation_key], "lifetime" => lifetime, "wake" => wake } }
        end

        def join
          operations = Array.try_convert(input["operations"]) || refuse(:invalid_operations, "operations must be an array")
          keys = operations.flat_map do |key|
            target_operation(key).response.fetch("receipt").fetch("result_task_keys")
          end.uniq
          refuse(:empty_join, "join needs accepted task results") if keys.empty?
          standing = AgentRuns::ExpansionOwnership.standing(@loop, keys).values.flatten.uniq
          sources = @loop.agent_run_tasks.where(node_key: standing).order(:id).map { |row| AgentRuns::Tasks::Known.of(row) }
          barrier = Step::Barrier.new(sources: sources, until: input.fetch("until", "all"),
            losers: input["losers"], on_failure: "absorb")
          append_steps([barrier])
        end

        def refuse(code, message) = raise Lower::Refusal.new(code, message)
    end
  end
end
