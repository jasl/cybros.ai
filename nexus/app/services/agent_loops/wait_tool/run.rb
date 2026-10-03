module AgentLoops
  module WaitTool
    # Waiting is another graph step, so tools in the same fan can keep running
    # while the ordinary continuation waits for this observation's finite park.
    class Run
      SUFFIX = "-wait-1".freeze

      def self.call(node:) = new(node: node).call

      def initialize(node:)
        @node = node
      end

      def call
        return :not_running unless @node.status == "running"
        return :not_mutable unless @node.agent_loop.graph_mutable?
        return settle("Waiting for the existing task.") if
          @node.agent_loop.agent_loop_nodes.exists?(node_key: wait_key)

        input = @node.tool_input
        step = Tasks::Step::Wait.new(task: input["task"], agent_loop: input["agent_loop"],
          key: wait_key, timeout_ms: input["timeout_ms"])
        result = Tasks::Append.call(Tasks::Append::Command.kernel(
          agent_loop: @node.agent_loop, steps: [step], tip: KernelTool.branch_tip(@node),
          origin: "kernel", expansion_parent: @node, holder: :kernel,
          head: (KernelTool.continuation_of(@node)&.node_key if @node.tool_call_id),
          replaces: (@node.node_key unless @node.tool_call_id)
        ))
        if result.applied? || result.outcome == :duplicate_task_key
          settle("Waiting for the existing task.")
        else
          reason = result.errors.first&.fetch("code", nil) || result.outcome
          settle("The wait was refused: #{reason}.", is_error: true)
        end
      end

      private

        def wait_key = "#{@node.node_key}#{SUFFIX}"

        def settle(text, is_error: false)
          KernelTool.settle(@node, text, is_error: is_error, title: "wait")
        end
    end
  end
end
