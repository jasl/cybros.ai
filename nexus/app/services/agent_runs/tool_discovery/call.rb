module AgentRuns
  module ToolDiscovery
    # Invoke through the same lowering and append doors as executor-authored
    # work. The child keeps the declaration's route and its caller's origin,
    # so authorizing the wrapper never authorizes the actual tool's effect.
    class Call
      def self.call(...) = new(...).call

      def initialize(node:)
        @node = node
      end

      def call
        agent_run = @node.agent_run
        return :not_running unless @node.status == "running"
        return :not_mutable unless agent_run.graph_mutable?
        return settle if agent_run.agent_run_tasks.exists?(node_key: root_key)

        input = @node.tool_input
        name = String.try_convert(input["name"])
        arguments = Hash.try_convert(input["input"])
        if name.blank? || arguments.nil?
          return settle("parameter_invalid: name must be nonempty text and input must be an object.", is_error: true)
        end

        steps = Executors::TaskOperations::Lower.new(@node).call([
          { "tool" => { "key" => root_key, "name" => name, "input" => arguments } },
        ])
        result = Tasks::Append.call(Tasks::Append::Command.kernel(
          agent_run: agent_run, steps: steps, tip: KernelTool.branch_tip(@node),
          origin: @node.authored_by, expansion_parent: @node,
          head: (KernelTool.continuation_of(@node)&.node_key if @node.tool_call_id),
          replaces: (@node.node_key if @node.tool_call_id.nil?)
        ))
        if result.applied?
          settle
        else
          detail = result.errors.first&.fetch("code", nil) || result.outcome
          settle("tool_call refused: #{detail}.", is_error: true)
        end
      rescue Executors::TaskOperations::Lower::Refusal => error
        settle("#{error.code}: #{error.message}", is_error: true)
      end

      private

        def root_key = "#{@node.node_key}-tool-1"

        def settle(text = "Tool call started.", is_error: false)
          KernelTool.settle(@node, text, title: "tool call", is_error: is_error)
        end
    end
  end
end
