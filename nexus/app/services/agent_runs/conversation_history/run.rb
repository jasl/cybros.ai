module AgentRuns
  module ConversationHistory
    # The tools and member doors share their query, visibility and output bounds.
    # A standalone loop has the same workspace history as a conversational loop.
    class Run
      def self.call(node:) = new(node: node).call

      def initialize(node:)
        @node = node
        @loop = node.agent_run
      end

      def call
        return :not_running unless @node.status == "running"
        return :not_mutable unless @loop.graph_mutable?

        workspace = Workspace.data_accessible_to(@loop.answering_user).browsable.find(@loop.workspace_id)
        result = if @node.tool_name == "session_search"
          ::Conversations::History::Search.call(workspace: workspace, user: @loop.answering_user,
            **::Conversations::History::Parameters.search(@node.tool_input))
        else
          read(workspace)
        end
        settle(JSON.generate(result))
      rescue ::Conversations::History::Parameters::Invalid => error
        settle("parameter_invalid: #{error.message}", is_error: true)
      rescue ActiveRecord::RecordNotFound
        settle("not_found: no readable conversation or turn at this address", is_error: true)
      end

      private

        def read(workspace)
          input = @node.tool_input
          conversation = Conversation.visible_to(@loop.answering_user, workspace: workspace)
            .find_by!(public_id: input["session_id"].to_s)
          options = input.except("around_turn_id").merge(
            "around_turn_public_id" => input["around_turn_id"]
          )
          ::Conversations::History::Read.call(conversation: conversation,
            **::Conversations::History::Parameters.read(options))
        end

        def settle(text, is_error: false)
          Parks::Settle.call(node: @node, trusted: true, outcome: "completed",
            content: text, is_error: is_error).outcome
        end
    end
  end
end
